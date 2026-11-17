#include "../game_structs.hpp"
#include "../native_predict.hpp"
#include "../native_planner.hpp"

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

class MockMem final : public iad::MemReader {
public:
    static constexpr uintptr_t kBase = 0x10000000u;
    static constexpr size_t kSize = 16u * 1024u * 1024u;

    std::vector<uint8_t> mem;
    uintptr_t allocCursor = 0x900000u;

    MockMem() : mem(kSize, 0) {}

    void reset() {
        std::fill(mem.begin(), mem.end(), 0);
        allocCursor = 0x900000u;
    }

    uintptr_t alloc(size_t bytes, size_t align = 16) {
        uintptr_t p = (allocCursor + (align - 1)) & ~(align - 1);
        assert(p + bytes <= kSize);
        allocCursor = p + bytes;
        return kBase + p;
    }

    bool readable(uintptr_t addr, size_t bytes) const override {
        return addr >= kBase && bytes <= kSize && (addr - kBase) <= (kSize - bytes);
    }

    bool readBytes(uintptr_t addr, void* out, size_t bytes) const override {
        if (!readable(addr, bytes)) return false;
        std::memcpy(out, mem.data() + (addr - kBase), bytes);
        return true;
    }

    template <typename T>
    void w(uintptr_t addr, const T& val) {
        assert(readable(addr, sizeof(T)));
        std::memcpy(mem.data() + (addr - kBase), &val, sizeof(T));
    }

    void wPtr(uintptr_t addr, uintptr_t target) {
        w<uint32_t>(addr, static_cast<uint32_t>(target));
    }

    void writeMsvcString(uintptr_t addr, const char* s) {
        uint32_t len = static_cast<uint32_t>(std::strlen(s));
        if (len < 16u) {
            for (size_t i = 0; i <= len; ++i) w<uint8_t>(addr + i, static_cast<uint8_t>(s[i]));
            w<uint32_t>(addr + 0x10u, len);
            w<uint32_t>(addr + 0x14u, 15u);
        } else {
            uintptr_t heap = alloc(len + 1u);
            for (size_t i = 0; i <= len; ++i) w<uint8_t>(heap + i, static_cast<uint8_t>(s[i]));
            wPtr(addr, heap);
            w<uint32_t>(addr + 0x10u, len);
            w<uint32_t>(addr + 0x14u, len);
        }
    }

    void writeSprite(uintptr_t spriteAddr, const char* anim, float frame, bool playing, bool flipX = false) {
        uintptr_t animData = alloc(32);
        writeMsvcString(animData, anim);
        wPtr(spriteAddr + iad::Offsets::Sprite::kAnimData, animData);
        w<float>(spriteAddr + iad::Offsets::Sprite::kFrame, frame);
        w<uint8_t>(spriteAddr + iad::Offsets::Sprite::kPlaying, playing ? 1 : 0);
        w<uint8_t>(spriteAddr + iad::Offsets::Sprite::kFlipX, flipX ? 1 : 0);
    }
};

struct WorldFixture {
    MockMem m;
    uintptr_t mgr = 0;
    uintptr_t game = 0;
    uintptr_t room = 0;
    uintptr_t desc = 0;
    uintptr_t descData = 0;
    uintptr_t player = 0;
    std::vector<uintptr_t> entities;

    static constexpr uint32_t kSeed = 0x12345678u;

    void initBase(int width = 15, int height = 9, int shape = 1, int roomType = 1) {
        m.reset();
        entities.clear();
        mgr = m.alloc(0x50000u);
        game = m.alloc(0x70000u);
        room = m.alloc(0x2000u);
        desc = m.alloc(0x40u);
        descData = m.alloc(0x80u);
        player = m.alloc(0x2200u);

        m.wPtr(MockMem::kBase + iad::Offsets::kManagerRva, mgr);
        m.wPtr(MockMem::kBase + iad::Offsets::kGameRva, game);
        m.w<int>(mgr + iad::Offsets::Manager::kState, 2);
        m.w<uint32_t>(mgr + iad::Offsets::Manager::kTick60, 0u);

        m.wPtr(game + iad::Offsets::Game::kRoom, room);
        uintptr_t pVec = m.alloc(16);
        m.wPtr(pVec, player);
        m.wPtr(game + iad::Offsets::Game::kPlayersBegin, pVec);
        m.wPtr(game + iad::Offsets::Game::kPlayersEnd, pVec + 4);
        m.w<int>(game + iad::Offsets::Game::kFrameCount, 120);

        m.wPtr(room + iad::Offsets::Room::kDescriptor, desc);
        m.wPtr(desc + iad::Offsets::Room::kDescData, descData);
        m.w<int>(descData + iad::Offsets::Room::kDataType, roomType);
        m.w<int>(descData + iad::Offsets::Room::kDataShape, shape);
        m.w<int>(room + iad::Offsets::Room::kType, roomType);
        m.w<int>(room + iad::Offsets::Room::kGridWidth, width);
        m.w<int>(room + iad::Offsets::Room::kGridHeight, height);
        m.w<int>(room + iad::Offsets::Room::kSpawnFrame, 0);
        m.w<iad::Vec2>(room + iad::Offsets::Room::kTopLeft, {60.0f, 140.0f});
        m.w<iad::Vec2>(room + iad::Offsets::Room::kBottomRight,
                       {60.0f + (width - 2) * 40.0f, 140.0f + (height - 2) * 40.0f});

        // Init player
        m.w<uint8_t>(player + iad::Offsets::Entity::kExists, 1);
        m.w<int>(player + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntPlayer);
        m.w<uint32_t>(player + iad::Offsets::Entity::kInitSeed, kSeed);
        m.w<iad::Vec2>(player + iad::Offsets::Entity::kPos, {320.0f, 280.0f});
        m.w<iad::Vec2>(player + iad::Offsets::Entity::kVel, {0.0f, 0.0f});
        m.w<float>(player + iad::Offsets::Entity::kSize, 10.0f);
        m.w<float>(player + iad::Offsets::Player::kMoveSpeed, 1.0f);
        m.w<float>(player + iad::Offsets::Player::kMaxFireDelay, 10.0f);
        m.w<float>(player + iad::Offsets::Player::kDamage, 3.5f);
        m.w<uint8_t>(player + iad::Offsets::Player::kControlsEnabled, 1);
        m.w<int>(player + iad::Offsets::Player::kControlsCooldown, 0);
        entities.push_back(player);
        syncEntities();
    }

    void syncEntities() {
        size_t n = entities.size();
        uintptr_t arr = m.alloc(std::max<size_t>(1, n) * 4u);
        for (size_t i = 0; i < n; ++i) m.wPtr(arr + i * 4u, entities[i]);
        m.wPtr(room + iad::Offsets::Room::kEntityData, arr);
        m.w<uint32_t>(room + iad::Offsets::Room::kEntityCount, static_cast<uint32_t>(n));
    }

    uintptr_t addGridEntity(int idx, int type, int variant, int state, int coll,
                            const char* anim = nullptr, float frame = 0.0f, bool playing = false) {
        uintptr_t ge = m.alloc(0x200u);
        m.w<int>(ge + iad::Offsets::Grid::kType, type);
        m.w<int>(ge + iad::Offsets::Grid::kVariant, variant);
        m.w<int>(ge + iad::Offsets::Grid::kState, state);
        m.w<int>(ge + iad::Offsets::Grid::kGridIdx, idx);
        m.w<int>(ge + iad::Offsets::Grid::kCollisionClass, coll);
        if (anim) m.writeSprite(ge + iad::Offsets::Grid::kSprite, anim, frame, playing);
        m.wPtr(room + iad::Offsets::Room::kGridEntities + static_cast<uintptr_t>(idx) * 4u, ge);
        return ge;
    }

    uintptr_t addProjectile(iad::Vec2 pos, iad::Vec2 vel, uint64_t pflags = 0, float size = 4.0f,
                            float height = -23.0f, float fallSpeed = 0.0f, float fallAccel = 0.0f,
                            int entityColl = iad::IsaacEnums::kEntCollPlayerOnly,
                            int gridColl = iad::IsaacEnums::kGridCollWall) {
        uintptr_t e = m.alloc(0x600u);
        m.w<uint8_t>(e + iad::Offsets::Entity::kExists, 1);
        m.w<int>(e + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntProjectile);
        m.w<int>(e + iad::Offsets::Entity::kSpawnerType, 10);
        m.w<int>(e + iad::Offsets::Entity::kEntityColl, entityColl);
        m.w<int>(e + iad::Offsets::Entity::kGridColl, gridColl);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kPos, pos);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kVel, vel);
        m.w<float>(e + iad::Offsets::Entity::kSize, size);
        m.w<float>(e + iad::Offsets::Entity::kTimeScale, 1.0f);
        m.w<float>(e + iad::Offsets::Projectile::kHeight, height);
        m.w<float>(e + iad::Offsets::Projectile::kFallingSpeed, fallSpeed);
        m.w<float>(e + iad::Offsets::Projectile::kFallingAccel, fallAccel);
        m.w<float>(e + iad::Offsets::Projectile::kScale, 1.0f);
        m.w<float>(e + iad::Offsets::Projectile::kAcceleration, 1.0f);
        m.w<uint64_t>(e + iad::Offsets::Projectile::kFlags, pflags);
        entities.push_back(e);
        syncEntities();
        return e;
    }

    uintptr_t addLaser(iad::Vec2 origin, float angleDeg, float len, float size = 12.0f,
                       float rotSpd = 0.0f, int rotDelay = 0, int subType = 0, float radius = 0.0f) {
        uintptr_t e = m.alloc(0x600u);
        m.w<uint8_t>(e + iad::Offsets::Entity::kExists, 1);
        m.w<int>(e + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntLaser);
        m.w<int>(e + iad::Offsets::Entity::kSubType, subType);
        m.w<uint8_t>(e + iad::Offsets::Laser::kFirstUpdate, 1);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kPos, origin);
        m.w<float>(e + iad::Offsets::Entity::kSize, size);
        m.w<float>(e + iad::Offsets::Laser::kAngleDeg, angleDeg);
        m.w<float>(e + iad::Offsets::Laser::kLaserLength, len);
        float rad = angleDeg * 0.0174532925f;
        m.w<iad::Vec2>(e + iad::Offsets::Laser::kEndPoint,
                       {origin.x + std::cos(rad) * len, origin.y + std::sin(rad) * len});
        m.w<float>(e + iad::Offsets::Laser::kRadius, radius);
        m.w<uint8_t>(e + iad::Offsets::Laser::kIsActiveRotating, rotSpd != 0.0f ? 1 : 0);
        m.w<float>(e + iad::Offsets::Laser::kRotationSpd, rotSpd);
        m.w<int>(e + iad::Offsets::Laser::kRotationDelay, rotDelay);
        m.w<int>(e + iad::Offsets::Laser::kTimeout, 30);
        entities.push_back(e);
        syncEntities();
        return e;
    }

    uintptr_t addNpc(int type, int variant, iad::Vec2 pos, iad::Vec2 vel = {0, 0},
                     const char* anim = "Walk", float frame = 0.0f, bool flipX = false,
                     int state = 0, float hp = 20.0f) {
        uintptr_t e = m.alloc(0xD00u);
        m.w<uint8_t>(e + iad::Offsets::Entity::kExists, 1);
        m.w<int>(e + iad::Offsets::Entity::kType, type);
        m.w<int>(e + iad::Offsets::Entity::kVariant, variant);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kPos, pos);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kVel, vel);
        m.w<float>(e + iad::Offsets::Entity::kSize, 13.0f);
        m.w<float>(e + iad::Offsets::Entity::kCollDamage, 1.0f);
        m.w<float>(e + iad::Offsets::Entity::kHitPoints, hp);
        m.w<int>(e + iad::Offsets::Entity::kEntityColl, iad::IsaacEnums::kEntCollAll);
        m.w<int>(e + iad::Offsets::NPC::kState, state);
        m.writeSprite(e + iad::Offsets::Entity::kSprite, anim, frame, true, flipX);
        entities.push_back(e);
        syncEntities();
        return e;
    }

    uintptr_t addBomb(iad::Vec2 pos, iad::Vec2 vel, int fuse, float radiusMult = 1.0f, int variant = 0) {
        uintptr_t e = m.alloc(0x600u);
        m.w<uint8_t>(e + iad::Offsets::Entity::kExists, 1);
        m.w<int>(e + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntBomb);
        m.w<int>(e + iad::Offsets::Entity::kVariant, variant);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kPos, pos);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kVel, vel);
        m.w<float>(e + iad::Offsets::Entity::kSize, 10.0f);
        m.w<float>(e + iad::Offsets::Entity::kFriction, 0.95f);
        m.w<int>(e + iad::Offsets::Bomb::kFuse, fuse);
        m.w<float>(e + iad::Offsets::Bomb::kExplosionDamage, 100.0f);
        m.w<float>(e + iad::Offsets::Bomb::kRadiusMultiplier, radiusMult);
        entities.push_back(e);
        syncEntities();
        return e;
    }

    uintptr_t addEffect(int variant, iad::Vec2 pos, float size = 24.0f, float sprScale = 1.0f,
                        float effScale = 1.0f, float collDmg = 0.0f) {
        uintptr_t e = m.alloc(0x600u);
        m.w<uint8_t>(e + iad::Offsets::Entity::kExists, 1);
        m.w<int>(e + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntEffect);
        m.w<int>(e + iad::Offsets::Entity::kVariant, variant);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kPos, pos);
        m.w<float>(e + iad::Offsets::Entity::kSize, size);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kSpriteScale, {sprScale, sprScale});
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kSizeMulti, {1.0f, 1.0f});
        m.w<float>(e + iad::Offsets::Effect::kScale, effScale);
        m.w<float>(e + iad::Offsets::Entity::kCollDamage, collDmg);
        entities.push_back(e);
        syncEntities();
        return e;
    }
};

void testCurvedSmartExplodeProjectiles() {
    WorldFixture f;
    f.initBase();

    // 1a. CURVE_LEFT projectile heading straight at y=280 curves AWAY (-Y) cleanly -> no false dodge!
    uintptr_t pMiss = f.addProjectile({220.0f, 280.0f}, {9.0f, 0.0f}, iad::IsaacEnums::kProjCurveLeft);
    f.m.w<float>(pMiss + iad::Offsets::Projectile::kCurvingStrength, 0.016f);

    iad::ThreatScene scene;
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed,
                                   iad::Shared::kFlagNativeEnabled, 450, 0, 60, scene));
    assert(scene.bullets.size() == 1);
    const auto& tr = scene.bullets[0];
    assert(tr.firstStep == 0 && tr.lastStep == scene.steps60);
    assert(tr.pts[tr.lastStep].y < 275.0f);

    iad::PlanResult missPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(missPlan.bestDir == -1); // curving away misses idle player!

    // 1b. CURVE_LEFT starting below (y=308) bends UP into idle (320,280): only curve prediction catches it!
    f.initBase();
    uintptr_t pHit = f.addProjectile({220.0f, 308.0f}, {9.0f, 0.0f}, iad::IsaacEnums::kProjCurveLeft);
    f.m.w<float>(pHit + iad::Offsets::Projectile::kCurvingStrength, 0.0048f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed,
                                   iad::Shared::kFlagNativeEnabled, 450, 0, 60, scene));
    iad::PlanResult hitPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(hitPlan.danger && hitPlan.bestDir >= 1);

    // 2. CHANGE_FLAGS / VELOCITY exact bucket swap at timeout=3 + SMART_PERFECT homing
    f.initBase();
    uintptr_t tp = f.addProjectile({200.0f, 280.0f}, {3.0f, 0.0f},
                                   iad::IsaacEnums::kProjChangeFlags | iad::IsaacEnums::kProjChangeVelocity);
    f.m.w<int32_t>(tp + iad::Offsets::Projectile::kChangeTimeout, 3);
    f.m.w<uint64_t>(tp + iad::Offsets::Projectile::kChangeFlags, iad::IsaacEnums::kProjSmartPerfect);
    f.m.w<float>(tp + iad::Offsets::Projectile::kChangeVelocity, 11.0f);
    f.m.w<float>(tp + iad::Offsets::Projectile::kHomingStrength, 0.8f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.bullets.size() == 1);
    float dxEarly = scene.bullets[0].pts[2].x - scene.bullets[0].pts[0].x;
    float dxLate  = scene.bullets[0].pts[12].x - scene.bullets[0].pts[10].x;
    assert(dxLate > dxEarly * 2.0f); // velocity jumped at timeout=3

    // 3. EXPLODE high-arcing projectile (ENTCOLL_NONE) creates BOTH 100px flight warning AND landing blast
    f.initBase();
    f.addProjectile({320.0f, 280.0f}, {0.0f, 0.0f}, iad::IsaacEnums::kProjExplode, 4.0f,
                    -65.0f, 3.0f, 1.0f, iad::IsaacEnums::kEntCollNone);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.discs.size() >= 2);
    assert(scene.discs[0].radius == 100.0f && scene.discs[0].warning == 1);
    auto explPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(explPlan.danger && explPlan.bestDir >= 1);

    // 4. Wall-turret projectile spawned at x=42 (< topLeft.x=60) flying +X into room is NOT culled at k=1!
    f.initBase();
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {120.0f, 280.0f});
    f.addProjectile({42.0f, 280.0f}, {8.0f, 0.0f}, 0, 5.0f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.bullets.size() == 1);
    assert(scene.bullets[0].lastStep >= 15);
    auto wallShotPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(wallShotPlan.danger && wallShotPlan.bestDir >= 1);

    std::puts("PASS curved, timed flag/velocity swap, SMART_PERFECT, EXPLODE & wall-turret projectiles");
}

void testLasersDogmaAndNpcWindups() {
    WorldFixture f;
    f.initBase();

    // Rotating laser sweeping down across player's standing position
    f.addLaser({180.0f, 250.0f}, -8.0f, 350.0f, 12.0f, 3.5f, 0);
    iad::ThreatScene scene;
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.lasers.size() == 1);
    auto plan = iad::solveNativePlan(scene, 0, -1, true);
    assert(plan.danger && plan.bestDir != -1);

    // Shrinking / expired OneHit lasers deal 0 damage and MUST be ignored
    f.initBase();
    uintptr_t lShrink = f.addLaser({180.0f, 280.0f}, 0.0f, 350.0f, 12.0f);
    f.m.w<uint8_t>(lShrink + iad::Offsets::Laser::kShrink, 1);
    uintptr_t lOneHit = f.addLaser({180.0f, 280.0f}, 0.0f, 350.0f, 12.0f);
    f.m.w<uint8_t>(lOneHit + iad::Offsets::Laser::kOneHit, 1);
    f.m.w<uint8_t>(lOneHit + iad::Offsets::Laser::kFirstUpdate, 0);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.lasers.empty());

    // Long curved laser (> 64 samples) preserves exact terminal sample (count - 1)
    f.initBase();
    uintptr_t lCurved = f.addLaser({100.0f, 180.0f}, 0.0f, 300.0f, 12.0f);
    uintptr_t sBuf = f.m.alloc(100 * sizeof(iad::Vec2));
    for (int i = 0; i < 100; ++i) {
        float t = static_cast<float>(i) / 99.0f;
        f.m.w<iad::Vec2>(sBuf + i * sizeof(iad::Vec2), {100.0f + 220.0f * t, 180.0f + 100.0f * t * t});
    }
    f.m.wPtr(lCurved + iad::Offsets::Laser::kSamplesBegin, sBuf);
    f.m.wPtr(lCurved + iad::Offsets::Laser::kSamplesEnd, sBuf + 100 * sizeof(iad::Vec2));
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.lasers.size() == 1);
    const auto& cl = scene.lasers[0];
    assert(cl.numPts >= 50 && cl.numPts <= iad::LaserHazard::kMaxSamples);
    // Terminal relative offset must equal (320, 280) - (100, 180) = (220, 100)!
    assert(std::abs(cl.pts[cl.numPts - 1].x - 220.0f) < 0.1f);
    assert(std::abs(cl.pts[cl.numPts - 1].y - 100.0f) < 0.1f);

    // Dogma (950.0) BrimstoneStartRight FlipX false (+X) vs FlipX true (-X)
    f.initBase();
    f.addNpc(iad::IsaacEnums::kEntDogma, 0, {320.0f, 280.0f}, {0, 0}, "BrimstoneStartRight", 32.0f, false);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(!scene.lasers.empty() && scene.lasers[0].pts[1].x > 100.0f);
    f.initBase();
    f.addNpc(iad::IsaacEnums::kEntDogma, 0, {320.0f, 280.0f}, {0, 0}, "BrimstoneStartRight", 32.0f, true);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(!scene.lasers.empty() && scene.lasers[0].pts[1].x < -100.0f);

    // Mom door arm (45.0 "ArmOpen") near right door: player near tip edge escapes Left
    f.initBase();
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {472.0f, 280.0f});
    f.addNpc(iad::IsaacEnums::kEntMom, 0, {560.0f, 280.0f}, {0, 0}, "ArmOpen", 8.0f, false);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.discs.size() >= 3);
    auto momPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(momPlan.danger && momPlan.bestDir >= 1);
    assert(iad::kCandX[momPlan.bestDir] <= 0.0f && momPlan.scores[2] > momPlan.scores[momPlan.bestDir]);

    std::puts("PASS rotating/fading/curved lasers, Dogma FlipX Brimstone & Mom Arm windups");
}

void testTwoStageTurnEscapeClosedLoop() {
    WorldFixture f;
    f.initBase();
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {320.0f, 280.0f});

    // Squeeze corridor: vertical beams at x=286 & x=354 ending at y=290 block immediate horizontal escape,
    // while bullets from top (320, 225, vy=+6) and bottom (320, 395, vy=-6.5) block idle/Up/straight-Down!
    f.addLaser({286.0f, 160.0f}, 90.0f, 130.0f, 8.0f);
    f.addLaser({354.0f, 160.0f}, 90.0f, 130.0f, 8.0f);
    f.addProjectile({320.0f, 225.0f}, {0.0f, 6.0f}, iad::IsaacEnums::kProjAnyHeightHit, 6.0f);
    f.addProjectile({320.0f, 395.0f}, {0.0f, -6.5f}, iad::IsaacEnums::kProjAnyHeightHit, 6.0f);

    iad::ThreatScene scene;
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    iad::PlanResult plan = iad::solveNativePlan(scene, 0, -1, true);
    assert(plan.valid && plan.danger);
    assert(plan.usedTurn);
    assert(plan.bestDir == 4); // Down first to clear laser tips, then turns L or R!

    // Closed-loop 60Hz simulation using exact 60Hz kinematics (`pos += vel`): verify ZERO collisions!
    iad::Vec2 pPos = scene.player.pos;
    iad::Vec2 pVel = scene.player.vel;
    auto kin = iad::planner_detail::PlayerKinematics::fast(scene.player);
    bool dummyMoved = false;
    int prevLocal = -1;
    iad::Vec2 cPos{320.0f, 225.0f}, cVel{0.0f, 6.0f};
    iad::Vec2 dPos{320.0f, 395.0f}, dVel{0.0f, -6.5f};

    for (int step = 0; step < 26; ++step) {
        f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, pPos);
        f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kVel, pVel);
        f.m.w<iad::Vec2>(f.entities[f.entities.size() - 2] + iad::Offsets::Entity::kPos, cPos);
        f.m.w<iad::Vec2>(f.entities[f.entities.size() - 1] + iad::Offsets::Entity::kPos, dPos);

        iad::ThreatScene st;
        assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, st));
        iad::PlanResult p = iad::solveNativePlan(st, 0, prevLocal, true);
        int chosen = (p.bestDir >= 0) ? p.bestDir : 0;
        prevLocal = chosen;

        assert((pPos - cPos).length() > 10.0f + 9.0f);
        assert((pPos - dPos).length() > 10.0f + 9.0f);

        iad::planner_detail::stepPlayer60(st.grid, 10.0f, false, false, iad::candVec(chosen), kin,
                                          pPos, pVel, dummyMoved);
        cPos += cVel * 0.5f;
        dPos += dVel * 0.5f;
    }
    assert(std::abs(pPos.x - 320.0f) > 18.0f);

    std::puts("PASS 2-stage turning escape (Down -> Left/Right) closed-loop 60Hz simulation (0 hits)");
}

void testNarrowRoomsKinematicsAndOnlineQueue() {
    WorldFixture f;
    iad::ThreatScene scene;

    // 1. Narrow horizontal corridor (ROOMSHAPE_IH = 2): TopLeft=(60,220), BottomRight=(580,340), grid origin STILL (40,120)!
    f.initBase(15, 9, 2, 1);
    f.m.w<iad::Vec2>(f.room + iad::Offsets::Room::kTopLeft, {60.0f, 220.0f});
    f.m.w<iad::Vec2>(f.room + iad::Offsets::Room::kBottomRight, {580.0f, 340.0f});
    // Row 2 (y=200) and Row 6 (y=360) are narrow walls; Row 4 (y=280) is open floor!
    for (int col = 0; col < 15; ++col) {
        f.addGridEntity(col + 2 * 15, 1, 0, 0, iad::IsaacEnums::kGridCollWall);
        f.addGridEntity(col + 6 * 15, 1, 0, 0, iad::IsaacEnums::kGridCollWall);
    }
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {320.0f, 280.0f});
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.grid.origin.x == 40.0f && scene.grid.origin.y == 120.0f);
    assert(scene.grid.indexAt(320.0f, 280.0f) == 7 + 4 * 15);
    assert(scene.grid.footprintSafe(320.0f, 280.0f, 10.0f, false));

    // Narrow vertical corridor (ROOMSHAPE_IV = 3): TopLeft=(220,140), BottomRight=(420,420)
    f.initBase(15, 9, 3, 1);
    f.m.w<iad::Vec2>(f.room + iad::Offsets::Room::kTopLeft, {220.0f, 140.0f});
    f.m.w<iad::Vec2>(f.room + iad::Offsets::Room::kBottomRight, {420.0f, 420.0f});
    for (int row = 0; row < 9; ++row) {
        f.addGridEntity(4 + row * 15, 1, 0, 0, iad::IsaacEnums::kGridCollWall);
        f.addGridEntity(10 + row * 15, 1, 0, 0, iad::IsaacEnums::kGridCollWall);
    }
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {320.0f, 280.0f});
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.grid.footprintSafe(320.0f, 280.0f, 10.0f, false));

    // 2. Exact 60Hz player kinematics: initial vel={4.0, 0} displaces ~3.5px on tick 1 (NOT halved to ~1.75px!)
    f.initBase();
    iad::Vec2 kPos{320.0f, 280.0f}, kVel{4.0f, 0.0f};
    bool kMoved = false;
    auto kinFast = iad::planner_detail::PlayerKinematics::fast(scene.player);
    iad::planner_detail::stepPlayer60(scene.grid, 10.0f, false, false, {0.0f, 0.0f}, kinFast, kPos, kVel, kMoved);
    assert(kMoved && (kPos.x - 320.0f) > 3.4f); // 4.0 * 0.880 = 3.52px!

    // 3. Online queueDelay = 4 (8 ticks): empty room MUST NOT lock blockedMask = 0x1FE,
    //    and holding straight into a bullet MUST keep straightScores[rawDir] > 0!
    f.initBase();
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 4, 60, scene));
    auto emptyOnline = iad::solveNativePlan(scene, 0, -1, true);
    assert(emptyOnline.blockedMask == 0); // open room has 0 blocked directions even at queueDelay=4!

    f.addProjectile({430.0f, 280.0f}, {-6.0f, 0.0f}, iad::IsaacEnums::kProjAnyHeightHit, 6.0f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 4, 60, scene));
    auto hitOnline = iad::solveNativePlan(scene, 2, -1, true); // player holding Right (2) into bullet
    assert(hitOnline.straightScores[2] >= iad::PlanResult::kHard);
    assert(hitOnline.bestDir != -1 && hitOnline.bestDir != 2);

    std::puts("PASS narrow rooms (shapes 2/3), exact 60Hz player kinematics & online queueDelay=4");
}

void testSpikesFlightSacrificeOwnershipCreepAndFireplace() {
    WorldFixture f;
    iad::ThreatScene scene;

    // 1. Floor spikes have GRIDCOLL_NONE: diagonal manual input toward spikes MUST hit DiscHazard (never wall-slide safe!)
    f.initBase();
    int spikeIdx = 8 + 4 * 15; // (360, 280) directly right of player at (320, 280)
    f.addGridEntity(spikeIdx, iad::IsaacEnums::kGridSpikes, 0, 0, iad::IsaacEnums::kGridCollNone, "Idle", 0.0f, true);
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {332.0f, 280.0f});
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    // Diagonal Right-Up (6) crosses spike disc at (360, 280) -> MUST NOT wall-slide safely!
    auto diagSpike = iad::solveNativePlan(scene, 6, -1, true);
    assert(diagSpike.danger && diagSpike.straightScores[6] >= iad::PlanResult::kHard);
    assert(diagSpike.bestDir != -1 && diagSpike.bestDir != 6);

    // 2. Flying player ignores normal spikes, red poop & ground creep, but avoids GRID_ROCK_SPIKED (17)!
    f.initBase();
    f.m.w<uint8_t>(f.player + iad::Offsets::Player::kCanFly, 1);
    f.addGridEntity(8 + 4 * 15, iad::IsaacEnums::kGridSpikes, 0, 0, iad::IsaacEnums::kGridCollNone, "Idle", 0.0f, true);
    f.addGridEntity(6 + 4 * 15, iad::IsaacEnums::kGridPoop, 1, 0, iad::IsaacEnums::kGridCollSolid);
    f.addEffect(22, {320.0f, 280.0f}, 30.0f, 2.0f); // CREEP_RED under flying player
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    auto flySafe = iad::solveNativePlan(scene, 2, -1, true);
    assert(!flySafe.danger && flySafe.bestDir == -1); // flying ignores all ground-only hazards!

    f.addGridEntity(7 + 3 * 15, iad::IsaacEnums::kGridRockSpiked, 0, 0, iad::IsaacEnums::kGridCollSolid); // (320, 240)
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {320.0f, 268.0f});
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    auto flySpikedRock = iad::solveNativePlan(scene, 3, -1, true); // flying Up into spiked rock!
    assert(flySpikedRock.danger && flySpikedRock.straightScores[3] >= iad::PlanResult::kHard);

    // 3. Sacrifice Room (type = 13) spikes: manual mode (allowPickups=true) allows sacrifice even when walking/flying,
    //    while AUTO mode (allowPickups=false) avoids Sacrifice spikes even when flying!
    f.initBase(15, 9, 1, 13);
    f.m.w<uint8_t>(f.player + iad::Offsets::Player::kCanFly, 1);
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {332.0f, 280.0f});
    f.addGridEntity(8 + 4 * 15, iad::IsaacEnums::kGridSpikes, 0, 0, iad::IsaacEnums::kGridCollNone, "Idle", 0.0f, true);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    auto sacManual = iad::solveNativePlan(scene, 2, -1, true);
    assert(sacManual.bestDir == -1 && sacManual.straightScores[2] <= 0.0); // manual sacrifice unblocked!
    auto sacAuto = iad::solveNativePlan(scene, 0, -1, false);
    assert(sacAuto.danger && sacAuto.straightScores[2] >= iad::PlanResult::kHard); // AUTO avoids it!

    // 4. Ownership: player familiar laser is ignored, while kEntFlagCharmed enemy bullet IS dodged!
    f.initBase();
    uintptr_t fam = f.m.alloc(0x600u);
    f.m.w<uint8_t>(fam + iad::Offsets::Entity::kExists, 1);
    f.m.w<int>(fam + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntFamiliar);
    f.m.w<uint32_t>(fam + iad::Offsets::Entity::kInitSeed, 0xABCDEF01u);
    f.m.wPtr(fam + iad::Offsets::Familiar::kPlayer, f.player);
    f.entities.push_back(fam);
    uintptr_t famLaser = f.addLaser({200.0f, 280.0f}, 0.0f, 300.0f, 14.0f);
    f.m.w<int>(famLaser + iad::Offsets::Entity::kSpawnerType, iad::IsaacEnums::kEntFamiliar);
    f.m.wPtr(famLaser + iad::Offsets::Entity::kSpawnerEntity, fam);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.lasers.empty()); // familiar Brimstone ignored!

    uintptr_t charmedProj = f.addProjectile({250.0f, 280.0f}, {8.0f, 0.0f}, 0, 5.0f);
    f.m.w<uint64_t>(charmedProj + iad::Offsets::Entity::kFlags, iad::IsaacEnums::kEntFlagCharmed);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.bullets.size() == 1); // charmed enemy bullet still hurts player -> dodged!

    // 5. Creep SpriteScale (+0xe4), MOM_FOOT_STOMP (29) 65px, harmless slowing creep (25, 94) ignored,
    //    and large 130px creep pool walks toward nearest edge instead of freezing at 0!
    f.initBase();
    f.addEffect(25, {320.0f, 280.0f}, 40.0f, 2.0f); // CREEP_WHITE (slow only, 0 damage)
    f.addEffect(94, {320.0f, 280.0f}, 40.0f, 2.0f); // CREEP_SLIPPERY_BROWN (slippery only, 0 damage)
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.discs.empty());

    f.initBase();
    f.addEffect(29, {320.0f, 280.0f}, 10.0f, 1.0f, 1.0f); // MOM_FOOT_STOMP -> 65px warning/area!
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.discs.size() == 1 && scene.discs[0].radius >= 65.0f);

    // Large pool (size=60, SpriteScale=2.0 -> radius = 132px; player at (335, 280) cannot exit in 27 ticks,
    // MUST run Right (+X, nearest edge) instead of freezing at idle 0!)
    f.initBase();
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {335.0f, 280.0f});
    f.addEffect(22, {320.0f, 280.0f}, 60.0f, 2.0f); // CREEP_RED radius = 60*2 + 12 = 132px
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.discs.size() == 1 && scene.discs[0].radius >= 130.0f);
    auto poolPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(poolPlan.inside && poolPlan.bestDir == 2); // runs Right toward nearest pool edge!

    // 6. Fireplace (Entity 33): CollDamage=1 avoided, extinguished CollDamage=0 (Size=13) ignored!
    f.initBase();
    uintptr_t fpOut = f.addNpc(iad::IsaacEnums::kEntFireplace, 0, {340.0f, 280.0f});
    f.m.w<float>(fpOut + iad::Offsets::Entity::kCollDamage, 0.0f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.discs.empty());
    f.m.w<float>(fpOut + iad::Offsets::Entity::kCollDamage, 1.0f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(!scene.discs.empty());

    std::puts("PASS floor spike non-slide, flight rules, Sacrifice Room, ownership, creep pool exit & fireplaces");
}

void testSafetyPausePassthroughInterpTwinAndBombCapsule() {
    WorldFixture f;
    f.initBase();

    iad::ThreatScene scene;
    // Wrong boundSeed rejected
    assert(!iad::collectThreatScene(f.m, MockMem::kBase, 0x99999999u, 1, 450, 0, 60, scene));
    // Paused flag sets paused=true and returns false
    assert(!iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed,
                                    iad::Shared::kFlagNativeEnabled | iad::Shared::kFlagPaused,
                                    450, 0, 60, scene));
    assert(scene.paused);

    // ControlsCooldown > 0, ControlsEnabled == 0, roomAge < 4, and Crawlspace (type=16) set passthrough=true!
    f.m.w<int>(f.player + iad::Offsets::Player::kControlsCooldown, 10);
    assert(!iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.passthrough);
    f.m.w<int>(f.player + iad::Offsets::Player::kControlsCooldown, 0);

    f.m.w<int>(f.room + iad::Offsets::Room::kSpawnFrame, 118); // roomAge = 120 - 118 = 2 < 4
    assert(!iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.passthrough);
    f.m.w<int>(f.room + iad::Offsets::Room::kSpawnFrame, 0);

    f.m.w<int>(f.room + iad::Offsets::Room::kType, 16); // non-Beast crawlspace
    assert(!iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.passthrough);
    f.m.w<int>(f.room + iad::Offsets::Room::kType, 1);

    // 60Hz kInterpolated=1 reads kInterpPrevPos instead of mid-tick kPos!
    f.initBase();
    uintptr_t ip = f.addProjectile({999.0f, 999.0f}, {4.0f, 0.0f});
    f.m.w<uint8_t>(ip + iad::Offsets::Entity::kInterpolated, 1);
    f.m.w<iad::Vec2>(ip + iad::Offsets::Entity::kInterpPrevPos, {250.0f, 280.0f});
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.bullets.size() == 1 && std::abs(scene.bullets[0].pts[0].x - 250.0f) < 0.1f);

    // Shared-controller Twin (Jacob & Esau): bullet aimed ONLY at Esau triggers dodge for shared controller!
    f.initBase();
    uintptr_t esau = f.m.alloc(0x2200u);
    f.m.w<uint8_t>(esau + iad::Offsets::Entity::kExists, 1);
    f.m.w<int>(esau + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntPlayer);
    f.m.w<uint32_t>(esau + iad::Offsets::Entity::kInitSeed, 0x55555555u);
    f.m.w<iad::Vec2>(esau + iad::Offsets::Entity::kPos, {320.0f, 340.0f});
    f.m.w<float>(esau + iad::Offsets::Entity::kSize, 10.0f);
    f.m.w<float>(esau + iad::Offsets::Player::kMoveSpeed, 1.0f);
    f.m.w<uint8_t>(esau + iad::Offsets::Player::kControlsEnabled, 1);
    f.m.w<int>(esau + iad::Offsets::Player::kControllerIndex, 0);
    uintptr_t pVec2 = f.m.alloc(16);
    f.m.wPtr(pVec2, f.player);
    f.m.wPtr(pVec2 + 4, esau);
    f.m.wPtr(f.game + iad::Offsets::Game::kPlayersBegin, pVec2);
    f.m.wPtr(f.game + iad::Offsets::Game::kPlayersEnd, pVec2 + 8);
    f.entities.push_back(esau);
    f.syncEntities();
    f.addProjectile({240.0f, 340.0f}, {9.0f, 0.0f}, iad::IsaacEnums::kProjAnyHeightHit, 6.0f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.hasTwin);
    auto twinPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(twinPlan.danger && twinPlan.bestDir != -1);

    // Bomb chain knockback capsule [blastPos, blastPos + sweep] covers both origin AND swept endpoint!
    f.initBase();
    f.addBomb({300.0f, 280.0f}, {0, 0}, 5, 1.0f);
    f.addBomb({340.0f, 280.0f}, {0, 0}, 20, 1.0f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 60, scene));
    assert(scene.steps60 >= 44); // blastHorizon auto-extended beyond 450ms for fuse=20!
    std::vector<iad::DiscHazard> hardBombs;
    for (const auto& d : scene.discs) if (d.warning == 0) hardBombs.push_back(d);
    assert(hardBombs.size() == 2);
    assert(hardBombs[1].isCapsule && hardBombs[1].sweepEndOffset.x > 80.0f);

    std::puts("PASS passthrough gates, 60Hz kInterpPrevPos, Jacob & Esau twin safety & Bomb chain capsule");
}

void benchmarkCombatRoom() {
    WorldFixture f;
    f.initBase();
    for (int i = 0; i < 40; ++i) {
        float ang = static_cast<float>(i) * 0.157f;
        uintptr_t p = f.addProjectile({320.0f + std::cos(ang) * 140.0f, 280.0f + std::sin(ang) * 110.0f},
                                      {-std::cos(ang) * 6.5f, -std::sin(ang) * 6.5f},
                                      iad::IsaacEnums::kProjCurveLeft | iad::IsaacEnums::kProjWiggle, 4.5f);
        f.m.w<float>(p + iad::Offsets::Projectile::kCurvingStrength, 0.008f);
    }
    for (int i = 0; i < 6; ++i) {
        f.addLaser({120.0f + i * 70.0f, 160.0f}, 90.0f, 260.0f, 12.0f, 1.2f);
    }
    for (int i = 0; i < 8; ++i) {
        f.addNpc(iad::IsaacEnums::kEntVis, 0, {140.0f + i * 45.0f, 180.0f}, {1.0f, 0.5f});
    }

    iad::ThreatScene scene;
    double collectUs = 0.0, planUs = 0.0;
    volatile int sink = 0;
    for (int iter = 0; iter < 200; ++iter) {
        auto t0 = std::chrono::steady_clock::now();
        assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 2, 60, scene));
        auto t1 = std::chrono::steady_clock::now();
        auto plan = iad::solveNativePlan(scene, 0, -1, true);
        auto t2 = std::chrono::steady_clock::now();
        collectUs += std::chrono::duration<double, std::micro>(t1 - t0).count();
        planUs += std::chrono::duration<double, std::micro>(t2 - t1).count();
        sink += plan.bestDir;
    }
    collectUs /= 200.0;
    planUs /= 200.0;
    double usPerFrame = collectUs + planUs;
    std::printf("BENCH 60Hz dense room (40 proj + 6 rot lasers + 8 npcs): %.1f us/frame (collect=%.1f plan=%.1f, sink=%d)\n",
                usPerFrame, collectUs, planUs, static_cast<int>(sink));
    assert(usPerFrame < 1000.0); // comfortably < 1ms/frame!
}

} // namespace

int main() {
    testCurvedSmartExplodeProjectiles();
    testLasersDogmaAndNpcWindups();
    testTwoStageTurnEscapeClosedLoop();
    testNarrowRoomsKinematicsAndOnlineQueue();
    testSpikesFlightSacrificeOwnershipCreepAndFireplace();
    testSafetyPausePassthroughInterpTwinAndBombCapsule();
    benchmarkCombatRoom();
    std::puts("PASS all native 60Hz memory-read & 2-stage planning tests");
    return 0;
}
