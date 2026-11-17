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
    static constexpr size_t kSize = 12u * 1024u * 1024u;

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
        m.w<uint32_t>(mgr + iad::Offsets::Manager::kTick60, 1u);

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
        m.w<uint8_t>(player + iad::Offsets::Player::kControlsEnabled, 1);
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
                            float height = -23.0f, float fallSpeed = 0.0f, float fallAccel = 0.0f) {
        uintptr_t e = m.alloc(0x600u);
        m.w<uint8_t>(e + iad::Offsets::Entity::kExists, 1);
        m.w<int>(e + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntProjectile);
        m.w<int>(e + iad::Offsets::Entity::kSpawnerType, 10);
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
        m.w<int>(e + iad::Offsets::Entity::kEntityColl, 4);
        m.w<int>(e + iad::Offsets::NPC::kState, state);
        m.writeSprite(e + iad::Offsets::Entity::kSprite, anim, frame, true, flipX);
        entities.push_back(e);
        syncEntities();
        return e;
    }

    uintptr_t addBomb(iad::Vec2 pos, iad::Vec2 vel, int countdown, float radiusMult = 1.0f) {
        uintptr_t e = m.alloc(0x600u);
        m.w<uint8_t>(e + iad::Offsets::Entity::kExists, 1);
        m.w<int>(e + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntBomb);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kPos, pos);
        m.w<iad::Vec2>(e + iad::Offsets::Entity::kVel, vel);
        m.w<float>(e + iad::Offsets::Entity::kSize, 10.0f);
        m.w<float>(e + iad::Offsets::Entity::kFriction, 0.95f);
        m.w<int>(e + iad::Offsets::Bomb::kExplosionCountdown, countdown);
        m.w<float>(e + iad::Offsets::Bomb::kExplosionDamage, 100.0f);
        m.w<float>(e + iad::Offsets::Bomb::kRadiusMultiplier, radiusMult);
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
                                   iad::Shared::kFlagNativeEnabled, 450, 0, 36, scene));
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
                                   iad::Shared::kFlagNativeEnabled, 450, 0, 36, scene));
    iad::PlanResult hitPlan = iad::solveNativePlan(scene, 0, -1, true);
    if (!hitPlan.danger || hitPlan.bestDir < 1) {
        std::fprintf(stderr, "DBG curve: danger=%d best=%d s0=%.1f first=%d last=%d rad=%.1f\n",
                     hitPlan.danger, hitPlan.bestDir, hitPlan.scores[0],
                     scene.bullets[0].firstStep, scene.bullets[0].lastStep, scene.bullets[0].radius);
        for (int k = 0; k <= scene.bullets[0].lastStep; k += 4) {
            std::fprintf(stderr, "  k=%d (%.1f, %.1f)\n", k, scene.bullets[0].pts[k].x, scene.bullets[0].pts[k].y);
        }
    }
    assert(hitPlan.danger && hitPlan.bestDir >= 1);

    // 2. CHANGE_FLAGS / VELOCITY after timeout + SMART homing
    f.initBase();
    uintptr_t tp = f.addProjectile({200.0f, 280.0f}, {3.0f, 0.0f},
                                   iad::IsaacEnums::kProjChangeFlags | iad::IsaacEnums::kProjChangeVelocity);
    f.m.w<int32_t>(tp + iad::Offsets::Projectile::kChangeTimeout, 3);
    f.m.w<uint64_t>(tp + iad::Offsets::Projectile::kChangeFlags, iad::IsaacEnums::kProjSmartPerfect);
    f.m.w<float>(tp + iad::Offsets::Projectile::kChangeVelocity, 11.0f);
    f.m.w<float>(tp + iad::Offsets::Projectile::kHomingStrength, 0.8f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert(scene.bullets.size() == 1);
    float dxEarly = scene.bullets[0].pts[2].x - scene.bullets[0].pts[0].x;
    float dxLate  = scene.bullets[0].pts[12].x - scene.bullets[0].pts[10].x;
    assert(dxLate > dxEarly * 2.0f); // velocity jumped at timeout=3

    // 3. EXPLODE lob projectile creates landing DiscHazard blast
    f.initBase();
    f.addProjectile({320.0f, 280.0f}, {0.0f, 0.0f}, iad::IsaacEnums::kProjExplode, 4.0f, -20.0f, 3.0f, 0.5f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert(!scene.discs.empty());
    assert(scene.discs[0].radius >= 80.0f);
    auto explPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(explPlan.danger && explPlan.bestDir >= 1);

    std::puts("PASS curved, timed flag/velocity swap, homing & exploding lob projectiles");
}

void testLasersDogmaAndNpcWindups() {
    WorldFixture f;
    f.initBase();

    // Rotating laser sweeping down across player's standing position
    f.addLaser({180.0f, 250.0f}, -8.0f, 350.0f, 12.0f, 3.5f, 0);
    iad::ThreatScene scene;
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert(scene.lasers.size() == 1);
    auto plan = iad::solveNativePlan(scene, 0, -1, true);
    assert(plan.danger && plan.bestDir != -1);

    // Dogma (950.0) BrimstoneStartRight FlipX false (+X) vs FlipX true (-X)
    f.initBase();
    f.addNpc(iad::IsaacEnums::kEntDogma, 0, {320.0f, 280.0f}, {0, 0}, "BrimstoneStartRight", 32.0f, false);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert(!scene.lasers.empty() && scene.lasers[0].pts[1].x > 100.0f);
    f.initBase();
    f.addNpc(iad::IsaacEnums::kEntDogma, 0, {320.0f, 280.0f}, {0, 0}, "BrimstoneStartRight", 32.0f, true);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert(!scene.lasers.empty() && scene.lasers[0].pts[1].x < -100.0f);

    // Mom door arm (45.0 "ArmOpen") near right door: player near tip edge escapes Left before full duration
    f.initBase();
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {472.0f, 280.0f});
    f.addNpc(iad::IsaacEnums::kEntMom, 0, {560.0f, 280.0f}, {0, 0}, "ArmOpen", 8.0f, false);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert(scene.discs.size() >= 3);
    auto momPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(momPlan.danger && momPlan.bestDir >= 1);
    assert(iad::kCandX[momPlan.bestDir] <= 0.0f && momPlan.scores[2] > momPlan.scores[momPlan.bestDir]);

    std::puts("PASS rotating lasers, Dogma FlipX Brimstone & Mom Arm windups");
}

void testTwoStageTurnEscapeClosedLoop() {
    // Construct a true L-turn squeeze trap where every straight ray suffers a hard hit,
    // while going Down for ~4 60Hz ticks and turning Left (or Right) escapes completely!
    WorldFixture f;
    f.initBase();
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {320.0f, 280.0f});

    // Horizontal line of fast vertical bullets closing from top across x=220..420 EXCEPT
    // the outer corridor y >= 312 can be escaped horizontally once cleared!
    // Wait: make:
    //  1) Vertical beams at x=284 and x=356 (wait: player at x=320, +/-36px, ending at y=308!)
    //     Wait: vertical laser segments at x=286 & x=354 from y=140..304 block L/R/LU/RU/LD/RD straight lines?
    //     Wait: straight Down passes (320, 280)->(320, 355), let's place an upcoming bullet at (320, 365) heading up,
    //     AND a horizontal laser turning active? Even simpler:
    //     - Place a fixed pit/rock/laser box on U/L/R/LU/RU at y <= 300:
    //       * Laser A: (286, 140) -> (286, 304) width 10  (blocks straight L/LU/LD at t<8)
    //       * Laser B: (354, 140) -> (354, 304) width 10  (blocks straight R/RU/RD at t<8)
    //       * Bullet C: (320, 230) vel (0, 6)  (blocks straight U and idle 0)
    //       * Bullet D: (320, 380) vel (0, -7) (blocks straight D — hits straight Down around y=325!)
    //     Wait: straight Down for 4 60Hz steps moves player from (320, 280) to ~(320, 293..310?),
    //     if Lasers A & B stop at y=282 + halfWidth=14 => bottom edge ~296, wait: once player reaches y=310
    //     (past laser A/B end!), turning Left or Right escapes BEFORE Bullet D arrives at y=310!!
    uintptr_t lA = f.addLaser({286.0f, 160.0f}, 90.0f, 130.0f, 8.0f); // ends y=290
    uintptr_t lB = f.addLaser({354.0f, 160.0f}, 90.0f, 130.0f, 8.0f); // ends y=290
    (void)lA; (void)lB;
    f.addProjectile({320.0f, 225.0f}, {0.0f, 6.0f}, iad::IsaacEnums::kProjAnyHeightHit, 6.0f);
    f.addProjectile({320.0f, 385.0f}, {0.0f, -6.5f}, iad::IsaacEnums::kProjAnyHeightHit, 6.0f);
    // Also place top block via bullet at y=200 or straight U hits bullet C.

    iad::ThreatScene scene;
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    iad::PlanResult plan = iad::solveNativePlan(scene, 0, -1, true);
    assert(plan.valid && plan.danger);
    assert(plan.usedTurn);
    assert(plan.bestDir == 4); // Down first to clear lasers, then turns L or R!

    // Closed-loop 60Hz simulation: step player + bullets and verify ZERO collisions!
    iad::Vec2 pPos = scene.player.pos;
    iad::Vec2 pVel = scene.player.vel;
    float f60 = std::sqrt(0.775f);
    float accel60 = 6.0f * scene.player.moveSpeed * (1.0f - f60);
    bool dummyMoved = false;
    int prevLocal = -1;
    // Bullets in simulation: C starts (320,225) vel (0,6), D starts (320,385) vel (0,-6.5)
    iad::Vec2 cPos{320.0f, 225.0f}, cVel{0.0f, 6.0f};
    iad::Vec2 dPos{320.0f, 385.0f}, dVel{0.0f, -6.5f};

    for (int step = 0; step < 26; ++step) {
        // Sync live player/bullet positions into memory for next 60Hz tick
        f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, pPos);
        f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kVel, pVel);
        f.m.w<iad::Vec2>(f.entities[f.entities.size() - 2] + iad::Offsets::Entity::kPos, cPos);
        f.m.w<iad::Vec2>(f.entities[f.entities.size() - 1] + iad::Offsets::Entity::kPos, dPos);

        iad::ThreatScene st;
        assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, st));
        iad::PlanResult p = iad::solveNativePlan(st, 0, prevLocal, true);
        int chosen = (p.bestDir >= 0) ? p.bestDir : 0;
        prevLocal = chosen;

        // Check zero overlap at current instant
        assert((pPos - cPos).length() > 10.0f + 9.0f);
        assert((pPos - dPos).length() > 10.0f + 9.0f);

        iad::planner_detail::stepPlayer60(st.grid, 10.0f, false, false, true,
                                          iad::candVec(chosen), f60, accel60, pPos, pVel, dummyMoved);
        cPos += cVel * 0.5f;
        dPos += dVel * 0.5f;
    }
    // Player should have exited horizontally away from x=320 column!
    assert(std::abs(pPos.x - 320.0f) > 18.0f);

    std::puts("PASS 2-stage turning escape (Down -> Left/Right) closed-loop 60Hz simulation (0 hits)");
}

void testTerrainLRoomSpikesAndOriginUnsafe() {
    WorldFixture f;
    // Shape 9 = top-left notch cut out of 28x16 (gridWidth=28, gridHeight=16)
    f.initBase(28, 16, 9, 1);
    iad::ThreatScene scene;
    // Put player in safe bottom-right quadrant of L-room
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {700.0f, 500.0f});
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert(scene.grid.isLShape());
    assert(!scene.grid.inBoundsPoint(100.0f, 180.0f, 5.0f)); // top-left cutout is outside L-room!
    assert(scene.grid.inBoundsPoint(700.0f, 500.0f, 5.0f));

    // Key block vs Rock for flying player, + Active vs Retracted ("Unsummon") spikes
    f.initBase();
    f.m.w<uint8_t>(f.player + iad::Offsets::Player::kCanFly, 1);
    int lockIdx = 5 + 4 * 15; // x=240, y=280 (just left of player at 320,280? Wait col 5 -> 40 + 5*40=240, row 4 -> 120+4*40=280)
    int rockIdx = 9 + 4 * 15; // col 9 -> 400,280
    int spikeIdx = 7 + 3 * 15; // col 7 -> 320,240
    int retSpikeIdx = 7 + 5 * 15; // col 7 -> 320,320
    f.addGridEntity(lockIdx, iad::IsaacEnums::kGridLock, 0, 0, iad::IsaacEnums::kGridCollSolid);
    f.addGridEntity(rockIdx, 2, 0, 0, iad::IsaacEnums::kGridCollSolid);
    f.addGridEntity(spikeIdx, iad::IsaacEnums::kGridSpikes, 0, 0, iad::IsaacEnums::kGridCollNone, "Idle", 0.0f, true);
    f.addGridEntity(retSpikeIdx, iad::IsaacEnums::kGridSpikes, 0, 0, iad::IsaacEnums::kGridCollNone, "Unsummon", 12.0f, true);

    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert((scene.grid.cells[lockIdx] & iad::RoomGrid::kSolidFly) != 0);
    assert((scene.grid.cells[rockIdx] & iad::RoomGrid::kSolidFly) == 0);
    assert((scene.grid.cells[spikeIdx] & iad::RoomGrid::kHazard) != 0);
    assert((scene.grid.cells[retSpikeIdx] & iad::RoomGrid::kHazard) == 0);

    // originUnsafe recovery: player slightly clipping wall at x=65 (margin=10) with incoming bullet from Right
    f.initBase();
    f.m.w<iad::Vec2>(f.player + iad::Offsets::Entity::kPos, {65.0f, 280.0f});
    f.addProjectile({220.0f, 280.0f}, {-12.0f, 0.0f}, iad::IsaacEnums::kProjAnyHeightHit, 6.0f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    auto recPlan = iad::solveNativePlan(scene, 0, -1, true);
    assert(recPlan.valid && recPlan.danger && recPlan.bestDir != -1);
    assert(recPlan.blockedMask != 510); // never locks out all 8 directions!

    std::puts("PASS L-room cutout, KeyBlock vs flight, retracted spikes & originUnsafe recovery");
}

void testSafetyPauseMirrorDeathmatchQueue() {
    WorldFixture f;
    f.initBase();

    iad::ThreatScene scene;
    // Wrong boundSeed rejected
    assert(!iad::collectThreatScene(f.m, MockMem::kBase, 0x99999999u, 1, 450, 0, 36, scene));
    // Paused flag sets paused=true and returns false
    assert(!iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed,
                                    iad::Shared::kFlagNativeEnabled | iad::Shared::kFlagPaused,
                                    450, 0, 36, scene));
    assert(scene.paused);

    // Engine PauseFrames sets paused=true
    f.m.w<int32_t>(f.game + iad::Offsets::Game::kPauseFrames, 2);
    assert(!iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 0, 36, scene));
    assert(scene.paused);
    f.m.w<int32_t>(f.game + iad::Offsets::Game::kPauseFrames, 0);

    // Deathmatch opponent player adds DiscHazard, while Beast room sets beast=true & magma discs
    f.m.w<int>(f.room + iad::Offsets::Room::kType, 30);
    uintptr_t opp = f.m.alloc(0x2200u);
    f.m.w<uint8_t>(opp + iad::Offsets::Entity::kExists, 1);
    f.m.w<int>(opp + iad::Offsets::Entity::kType, iad::IsaacEnums::kEntPlayer);
    f.m.w<uint32_t>(opp + iad::Offsets::Entity::kInitSeed, 0x87654321u);
    f.m.w<iad::Vec2>(opp + iad::Offsets::Entity::kPos, {350.0f, 280.0f});
    f.m.w<float>(opp + iad::Offsets::Entity::kSize, 10.0f);
    f.entities.push_back(opp);
    f.syncEntities();
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed,
                                    iad::Shared::kFlagNativeEnabled | iad::Shared::kFlagMirror,
                                    450, 4, 36, scene));
    assert(scene.deathmatch && scene.grid.mirror && scene.queueDelay30 == 4);
    assert(scene.discs.size() == 1);

    // Bomb chain push test: fast-fusing bomb 1 pushes later bomb 2 away
    f.initBase();
    f.addBomb({300.0f, 280.0f}, {0, 0}, 5, 1.0f);
    f.addBomb({340.0f, 280.0f}, {0, 0}, 20, 1.0f);
    assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 700, 0, 36, scene));
    std::vector<iad::DiscHazard> hardBombs;
    for (const auto& d : scene.discs) if (d.warning == 0) hardBombs.push_back(d);
    assert(hardBombs.size() == 2);
    // Bomb 2 should have non-zero sweep velocity in +X
    assert(hardBombs[1].vel.x > 1.0f);

    std::puts("PASS boundSeed isolation, IsPaused, Mirror/Deathmatch flags & Bomb chain knockback");
}

void benchmarkCombatRoom() {
    WorldFixture f;
    f.initBase();
    for (int i = 0; i < 40; ++i) {
        float ang = static_cast<float>(i) * 0.157f;
        uintptr_t p = f.addProjectile({320.0f + std::cos(ang) * 140.0f, 280.0f + std::sin(ang) * 110.0f},
                                      {-std::cos(ang) * 6.5f, -std::sin(ang) * 6.5f},
                                      iad::IsaacEnums::kProjCurveLeft | iad::IsaacEnums::kProjWiggle, 4.5f);
        f.m.w<float>(p + iad::Offsets::Projectile::kCurvingStrength, 0.06f);
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
        assert(iad::collectThreatScene(f.m, MockMem::kBase, WorldFixture::kSeed, 1, 450, 2, 36, scene));
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
    testTerrainLRoomSpikesAndOriginUnsafe();
    testSafetyPauseMirrorDeathmatchQueue();
    benchmarkCombatRoom();
    std::puts("PASS all native 60Hz memory-read & 2-stage planning tests");
    return 0;
}
