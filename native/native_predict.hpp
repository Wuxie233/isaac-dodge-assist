#pragma once

#include "game_structs.hpp"
#include <array>
#include <cctype>
#include <cstring>
#include <vector>

namespace iad {

// Geometric threat primitives emitted for the 60Hz planner.
// Time `t` is measured in 30Hz engine updates (each 60Hz sub-step is 0.5f updates).

struct BulletTrack {
    static constexpr int kMaxPts = 40; // covers up to kMaxSteps60 = 36 (600ms) + 1
    Vec2 pts[kMaxPts]{};               // pos at t = k * 0.5f
    float radius = 0.0f;
    float minX = 0.0f, maxX = 0.0f, minY = 0.0f, maxY = 0.0f;
    int firstStep = 0; // first k where segment [k-1 -> k] is valid (1-indexed)
    int lastStep = 0;  // last k valid (inclusive)
    uint8_t warning = 0;
};

struct DiscHazard {
    Vec2 pos;
    Vec2 vel;
    float radius = 0.0f;
    float fromT = 0.0f;
    float toT = 1e6f;
    uint8_t warning = 0;
};

struct LaserHazard {
    static constexpr int kMaxSamples = 48;
    Vec2 origin;
    Vec2 vel;
    Vec2 pts[kMaxSamples]{}; // offsets relative to origin
    int numPts = 0;
    float reach = 0.0f;
    float width = 12.0f;
    float radius = 0.0f;       // ring radius
    float angularSpeed = 0.0f; // deg per 30Hz update
    float rotDelay = 0.0f;     // updates
    float activeFrom = 0.0f;   // updates
    float timeoutT = 1e6f;     // updates
    bool ring = false;
    uint8_t warning = 0;
};

struct RoomGrid {
    enum CellFlag : uint8_t {
        kSolidGround = 1 << 0,
        kSolidFly    = 1 << 1,
        kHazard      = 1 << 2,
        kAutoAvoid   = 1 << 3,
    };

    int width = 15;
    int height = 9;
    int cellCount = 135;
    int shape = 1;
    int type = 1;
    bool beast = false;
    bool mirror = false;
    Vec2 topLeft{60.0f, 140.0f};
    Vec2 bottomRight{580.0f, 420.0f};
    Vec2 pitch{40.0f, 40.0f};
    Vec2 origin{40.0f, 120.0f};
    float beastGroundY = 420.0f;
    std::array<uint8_t, Offsets::Room::kMaxGridCells> cells{};

    bool isLShape() const { return shape >= 9 && shape <= 12; }

    int indexAt(float x, float y) const {
        if (pitch.x <= 0.0f || pitch.y <= 0.0f) return -1;
        int col = static_cast<int>(std::floor((x - origin.x) / pitch.x + 0.5f));
        int row = static_cast<int>(std::floor((y - origin.y) / pitch.y + 0.5f));
        if (col < 0 || col >= width || row < 0 || row >= height) return -1;
        int idx = col + row * width;
        return (idx >= 0 && idx < cellCount) ? idx : -1;
    }

    bool inBoundsPoint(float x, float y, float margin) const {
        if (beast) {
            float maxX = std::max(bottomRight.x + 140.0f, 720.0f);
            float minY = topLeft.y - 80.0f;
            float maxY = bottomRight.y + 70.0f;
            return x >= topLeft.x && x <= maxX && y >= minY && y <= maxY;
        }
        if (x < topLeft.x + margin || x > bottomRight.x - margin ||
            y < topLeft.y + margin || y > bottomRight.y - margin) {
            return false;
        }
        if (isLShape()) {
            // Exact interior notch cutout matching Room::GetClampedPosition (0x812f50).
            float midX = (topLeft.x + bottomRight.x) * 0.5f;
            float midY = (topLeft.y + bottomRight.y) * 0.5f;
            bool cutLeft = (shape == 9 || shape == 11);
            bool cutTop  = (shape == 9 || shape == 10);
            float dx = cutLeft ? std::max(0.0f, x - midX) : std::max(0.0f, midX - x);
            float dy = cutTop  ? std::max(0.0f, y - midY) : std::max(0.0f, midY - y);
            bool inCut = (cutLeft ? x <= midX : x >= midX) && (cutTop ? y <= midY : y >= midY);
            if (inCut || dx * dx + dy * dy <= margin * margin) return false;
        }
        return true;
    }

    bool cellPassable(int idx, bool canFly, bool allowHazard, bool allowPickups) const {
        if (idx < 0 || idx >= cellCount) return beast;
        uint8_t f = cells[idx];
        uint8_t solidMask = canFly ? kSolidFly : kSolidGround;
        if (f & solidMask) return false;
        if (!allowHazard && (f & kHazard)) return false;
        if (!allowPickups && (f & kAutoAvoid)) return false;
        return true;
    }

    bool footprintSafe(float x, float y, float radius, bool canFly,
                       bool allowHazard = false, bool allowPickups = true) const {
        float r = std::max(2.0f, radius - 1.0f);
        if (!beast && !isLShape() && pitch.x == 40.0f && pitch.y == 40.0f) {
            if (x - r < topLeft.x || x + r > bottomRight.x ||
                y - r < topLeft.y || y + r > bottomRight.y) {
                return false;
            }
            float ox = x - origin.x;
            float oy = y - origin.y;
            if (ox >= r && oy >= r) {
                int c0 = static_cast<int>((ox - r) * 0.025f + 0.5f);
                int c1 = static_cast<int>((ox + r) * 0.025f + 0.5f);
                int r0 = static_cast<int>((oy - r) * 0.025f + 0.5f);
                int r1 = static_cast<int>((oy + r) * 0.025f + 0.5f);
                if (c0 == c1 && r0 == r1) {
                    return cellPassable(c0 + r0 * width, canFly, allowHazard, allowPickups);
                }
                if (c1 - c0 <= 1 && r1 - r0 <= 1) {
                    if (cellPassable(c0 + r0 * width, canFly, allowHazard, allowPickups) &&
                        cellPassable(c1 + r0 * width, canFly, allowHazard, allowPickups) &&
                        cellPassable(c0 + r1 * width, canFly, allowHazard, allowPickups) &&
                        cellPassable(c1 + r1 * width, canFly, allowHazard, allowPickups)) {
                        return true;
                    }
                }
            }
        }
        if (!inBoundsPoint(x, y, 0.0f)) return false;
        int centerIdx = indexAt(x, y);
        if (!cellPassable(centerIdx, canFly, allowHazard, allowPickups)) return false;
        static constexpr float kDiag = 0.70710678f;
        static constexpr float kDirX[8] = {-1, 1, 0, 0, -kDiag, kDiag, -kDiag, kDiag};
        static constexpr float kDirY[8] = {0, 0, -1, 1, -kDiag, -kDiag, kDiag, kDiag};
        for (int i = 0; i < 8; ++i) {
            float px = x + kDirX[i] * r;
            float py = y + kDirY[i] * r;
            if (!inBoundsPoint(px, py, 0.0f)) return false;
            int idx = indexAt(px, py);
            if (!cellPassable(idx, canFly, allowHazard, allowPickups)) return false;
        }
        return true;
    }

    bool lineClear(Vec2 a, Vec2 b) const {
        Vec2 d = b - a;
        float len = d.length();
        if (len < 1.0f) return true;
        int n = std::min(32, std::max(1, static_cast<int>(len / 16.0f)));
        for (int i = 1; i < n; ++i) {
            float t = static_cast<float>(i) / static_cast<float>(n);
            Vec2 p = a + d * t;
            int idx = indexAt(p.x, p.y);
            if (idx < 0 || (cells[idx] & kSolidFly)) return false;
        }
        return true;
    }
};

struct PlayerState {
    uintptr_t ptr = 0;
    Vec2 pos;
    Vec2 vel;
    float size = 10.0f;
    float moveSpeed = 1.0f;
    bool canFly = false;
    bool slippery = false;
    int controllerIndex = 0;
    uint32_t initSeed = 0;
    float effectiveMaxFireDelay = 10.0f;
    float tearDamage = 3.5f;
};

struct ThreatScene {
    bool valid = false;
    bool paused = false;
    bool deathmatch = false;
    uint32_t tick60 = 0;
    int frameCount30 = 0;
    int steps60 = 27; // default 450ms @ 60Hz (27 * 0.5 updates)
    int queueDelay30 = 0;
    RoomGrid grid;
    PlayerState player;
    std::vector<BulletTrack> bullets;
    std::vector<DiscHazard> discs;
    std::vector<LaserHazard> lasers;

    void clear() {
        valid = false;
        paused = false;
        deathmatch = false;
        bullets.clear();
        discs.clear();
        lasers.clear();
    }
};

namespace detail {

inline bool strStartsWith(const char* s, const char* prefix) {
    while (*prefix) {
        if (*s != *prefix) return false;
        ++s; ++prefix;
    }
    return true;
}

inline bool strContainsCI(const char* s, const char* needle) {
    if (!needle[0]) return true;
    for (; *s; ++s) {
        const char* a = s;
        const char* b = needle;
        while (*a && *b && std::tolower(static_cast<unsigned char>(*a)) ==
                              std::tolower(static_cast<unsigned char>(*b))) {
            ++a; ++b;
        }
        if (!*b) return true;
    }
    return false;
}

inline bool readSpriteState(const MemReader& mem, uintptr_t spriteAddr,
                            char* animBuf, size_t animCap,
                            float& frameOut, bool& playingOut, bool& flipXOut) {
    animBuf[0] = '\0';
    frameOut = 0.0f;
    playingOut = false;
    flipXOut = false;
    if (!spriteAddr) return false;
    uintptr_t animData = mem.readPtr32(spriteAddr + Offsets::Sprite::kAnimData);
    if (!animData) return false;
    if (!mem.readMsvcString(animData, animBuf, animCap)) return false;
    mem.read(spriteAddr + Offsets::Sprite::kFrame, frameOut);
    uint8_t pl = 0, fx = 0;
    mem.read(spriteAddr + Offsets::Sprite::kPlaying, pl);
    mem.read(spriteAddr + Offsets::Sprite::kFlipX, fx);
    playingOut = (pl != 0);
    flipXOut = (fx != 0);
    return true;
}

inline bool unsupportedPlayerType(int playerType) {
    switch (playerType) {
        case 16: // PLAYER_THEFORGOTTEN
        case 17: // PLAYER_THESOUL
        case 29: // PLAYER_LAZARUS_B
        case 35: // PLAYER_THEFORGOTTEN_B
        case 37: // PLAYER_JACOB_B
        case 38: // PLAYER_LAZARUS2_B
        case 40: // PLAYER_THESOUL_B
            return true;
        default:
            return false;
    }
}

inline bool isActiveEnemyRaw(int type, int variant, uint8_t dead, uint64_t flags,
                               bool deathmatch, uint32_t initSeed, uint32_t boundSeed) {
    if (dead) return false;
    if (flags & (IsaacEnums::kEntFlagFriendly | IsaacEnums::kEntFlagBossDeath | IsaacEnums::kEntFlagNoQuery)) {
        return false;
    }
    if (deathmatch && type == IsaacEnums::kEntPlayer) {
        return initSeed != boundSeed;
    }
    if (type < 10 || type > 999) return false;
    if (type == 17 || type == 33 || type == 245 || type == 292 || type == 960 || type == 965) return false;
    if (type == 885 && variant == 10) return false;
    return true;
}

inline bool isPlayerOwned(const MemReader& mem, uintptr_t entAddr, bool deathmatch, uint32_t boundSeed) {
    std::array<uintptr_t, 8> seen{};
    uintptr_t cur = entAddr;
    for (int hop = 0; hop < 8 && cur; ++hop) {
        for (int k = 0; k < hop; ++k) {
            if (seen[k] == cur) return false;
        }
        seen[hop] = cur;
        int t = 0;
        uint32_t seed = 0;
        uint64_t flags = 0;
        if (!mem.read(cur + Offsets::Entity::kType, t)) return false;
        mem.read(cur + Offsets::Entity::kFlags, flags);
        mem.read(cur + Offsets::Entity::kInitSeed, seed);
        if (t == IsaacEnums::kEntPlayer) {
            return deathmatch ? (seed == boundSeed) : true;
        }
        if (flags & (IsaacEnums::kEntFlagFriendly | IsaacEnums::kEntFlagCharmed)) {
            return true;
        }
        uintptr_t spawner = mem.readPtr32(cur + Offsets::Entity::kSpawnerEntity);
        uintptr_t parent = mem.readPtr32(cur + Offsets::Entity::kParent);
        cur = spawner ? spawner : parent;
    }
    return false;
}

inline bool isEnemyCreepVariant(int variant) {
    switch (variant) {
        case 22: case 23: case 24: case 25: case 26:
        case 56: case 94: case 155: case 169: case 195:
            return true;
        default:
            return false;
    }
}

inline bool isExploderNpc(int type, int variant) {
    switch (type) {
        case IsaacEnums::kEntBoomFly: return variant == 0 || variant == 2 || variant == 6;
        case IsaacEnums::kEntMulligan: return variant == 2;
        case IsaacEnums::kEntLeech: return variant == 1 || variant == 2;
        case IsaacEnums::kEntBlackMaw:
        case IsaacEnums::kEntTickingSpd:
        case IsaacEnums::kEntPoisonMind:
        case IsaacEnums::kEntBlackBony:
        case IsaacEnums::kEntFlyBomb:
            return true;
        default:
            return false;
    }
}

inline bool isChaserExploder(int type, int variant) {
    switch (type) {
        case IsaacEnums::kEntMulligan: return variant == 2;
        case IsaacEnums::kEntLeech: return variant == 1 || variant == 2;
        case IsaacEnums::kEntBlackMaw:
        case IsaacEnums::kEntTickingSpd:
        case IsaacEnums::kEntFlyBomb:
            return true;
        default:
            return false;
    }
}

inline void addDirectedLaser(std::vector<LaserHazard>& out, Vec2 origin, Vec2 vel,
                             float angleDeg, float reach, float width,
                             float activeFrom, bool warning) {
    if (out.size() >= 64) return;
    LaserHazard h{};
    h.origin = origin;
    h.vel = vel;
    h.width = width;
    h.reach = reach;
    h.activeFrom = activeFrom;
    h.warning = warning ? 1 : 0;
    h.numPts = 2;
    h.pts[0] = {0.0f, 0.0f};
    h.pts[1] = Vec2{reach, 0.0f}.rotatedDeg(angleDeg);
    out.push_back(h);
}

inline void simulateProjectile(const MemReader& mem, uintptr_t entAddr,
                               const ThreatScene& scene, float horizonUpdates, int steps60,
                               BulletTrack& track, std::vector<DiscHazard>& discs) {
    Vec2 pos{}, vel{};
    float size = 4.0f, timeScale = 1.0f, age = 0.0f;
    int variant = 0, spawnerType = 0;
    mem.read(entAddr + Offsets::Entity::kVariant, variant);
    mem.read(entAddr + Offsets::Entity::kSpawnerType, spawnerType);
    mem.read(entAddr + Offsets::Entity::kPos, pos);
    mem.read(entAddr + Offsets::Entity::kVel, vel);
    mem.read(entAddr + Offsets::Entity::kSize, size);
    mem.read(entAddr + Offsets::Entity::kTimeScale, timeScale);
    mem.read(entAddr + Offsets::Entity::kAgeFloat, age);
    if (!std::isfinite(pos.x) || !std::isfinite(pos.y) || !std::isfinite(vel.x) || !std::isfinite(vel.y)) return;
    timeScale = std::max(0.1f, std::min(2.5f, std::isfinite(timeScale) ? timeScale : 1.0f));

    float height = -10.0f, fallSpeed = 0.0f, fallAccel = 0.0f;
    float homing = 0.0f, curving = 0.0f, accel = 1.0f, changeVel = 0.0f;
    uint64_t flags = 0, changeFlags = 0;
    int32_t wiggleOff = 0, changeTimeout = 0;
    mem.read(entAddr + Offsets::Projectile::kHeight, height);
    mem.read(entAddr + Offsets::Projectile::kFallingSpeed, fallSpeed);
    mem.read(entAddr + Offsets::Projectile::kFallingAccel, fallAccel);
    mem.read(entAddr + Offsets::Projectile::kHomingStrength, homing);
    mem.read(entAddr + Offsets::Projectile::kCurvingStrength, curving);
    mem.read(entAddr + Offsets::Projectile::kAcceleration, accel);
    mem.read(entAddr + Offsets::Projectile::kFlags, flags);
    mem.read(entAddr + Offsets::Projectile::kWiggleOffset, wiggleOff);
    mem.read(entAddr + Offsets::Projectile::kChangeFlags, changeFlags);
    mem.read(entAddr + Offsets::Projectile::kChangeVelocity, changeVel);
    mem.read(entAddr + Offsets::Projectile::kChangeTimeout, changeTimeout);

    if (flags & IsaacEnums::kProjCantHitPlayer) return;

    Vec2 targetPos = scene.player.pos;
    uintptr_t targetPtr = mem.readPtr32(entAddr + Offsets::Entity::kTarget);
    if (targetPtr) {
        Vec2 tp{};
        if (mem.read(targetPtr + Offsets::Entity::kPos, tp) && std::isfinite(tp.x) && std::isfinite(tp.y)) {
            targetPos = tp;
        }
    }

    // Check max possible reach against player to avoid tracking irrelevant off-map bullets
    float estMaxSpeed = std::max(vel.length(), std::abs(changeVel)) + 6.0f;
    float reachLimit = 6.5f * scene.player.moveSpeed * horizonUpdates + size + 160.0f + estMaxSpeed * horizonUpdates;
    if ((pos - scene.player.pos).length() > reachLimit && (flags & IsaacEnums::kProjContinuum) == 0) {
        return;
    }

    int clampedSteps = std::min(steps60, BulletTrack::kMaxPts - 1);
    track.radius = std::max(1.0f, size) + 3.0f;
    track.pts[0] = pos;
    bool anyHeight = (flags & IsaacEnums::kProjAnyHeightHit) != 0;
    bool activeAtZero = anyHeight || (height >= -50.0f && height <= 20.0f);
    track.firstStep = activeAtZero ? 0 : 1;
    track.lastStep = activeAtZero ? 0 : -1;
    track.warning = 0;
    track.minX = track.maxX = pos.x;
    track.minY = track.maxY = pos.y;

    constexpr float kTwoPi = 6.28318530718f;
    float dtStep = 0.5f * timeScale;
    bool landed = false;
    bool continuum = (flags & IsaacEnums::kProjContinuum) != 0;
    bool noWallCollide = (flags & IsaacEnums::kProjNoWallCollide) != 0;
    float prevH = height;

    for (int k = 1; k <= clampedSteps; ++k) {
        if (landed) break;
        float dt = dtStep;

        // Timed behavior switches (CHANGE_FLAGS_AFTER_TIMEOUT / CHANGE_VELOCITY_AFTER_TIMEOUT)
        if (changeTimeout > 0) {
            float remaining = static_cast<float>(changeTimeout) - (k - 1) * 0.5f;
            if (remaining <= 0.0f) {
                if (flags & IsaacEnums::kProjChangeVelocity) {
                    vel = vel.resized(changeVel);
                    flags &= ~IsaacEnums::kProjChangeVelocity;
                }
                if (flags & IsaacEnums::kProjChangeFlags) {
                    flags = changeFlags;
                }
            }
        }

        // Homing (SMART / SMART_PERFECT) from 0x6585c0
        if ((flags & (IsaacEnums::kProjSmart | IsaacEnums::kProjSmartPerfect)) && homing != 0.0f) {
            Vec2 toTarget = targetPos - pos;
            float dist = toTarget.length();
            if (dist > 1.0f && (dist < 100.0f || (flags & IsaacEnums::kProjSmartPerfect))) {
                vel += toTarget.normalized() * (1.4f * homing * dt);
                vel *= std::pow(0.92f, std::min(4.0f, std::abs(homing)) * dt);
            }
        }

        // Curving (CURVE_LEFT / CURVE_RIGHT) from 0x658ec3
        if ((flags & (IsaacEnums::kProjCurveLeft | IsaacEnums::kProjCurveRight)) && curving != 0.0f) {
            float spd = vel.length();
            if (spd > 1e-4f) {
                Vec2 perp = (flags & IsaacEnums::kProjCurveLeft)
                    ? Vec2{vel.y, -vel.x}
                    : Vec2{-vel.y, vel.x};
                vel = (vel + perp * (spd * curving * dt)).resized(spd);
            }
        }

        // Acceleration / Deceleration / AccelerateEx from 0x659a4e..0x659c10
        if ((flags & IsaacEnums::kProjAccelerate) && accel > 0.01f) {
            vel *= std::pow(accel, dt);
        }
        if ((flags & IsaacEnums::kProjDecelerate) && accel > 0.01f) {
            vel *= std::pow(1.0f / accel, dt);
        }
        if ((flags & IsaacEnums::kProjAccelerateEx) && accel > 0.01f) {
            float blendAge = std::min(1.0f, (age + k * dt) / 20.0f);
            float factor = 1.0f + (accel - 1.0f) * blendAge;
            vel *= std::pow(std::max(0.05f, factor), dt);
        }

        // Position step
        Vec2 nextPos = pos + vel * dt;

        // Oscillatory wave offsets (WIGGLE / MEGA_WIGGLE / SINE_VELOCITY) from 0x65951f..0x65976e
        float curAge = age + k * dt;
        if (flags & IsaacEnums::kProjSineVelocity) {
            nextPos += vel * (std::sin(curAge * kTwoPi / 30.0f) * 0.5f);
        }
        if (flags & (IsaacEnums::kProjWiggle | IsaacEnums::kProjMegaWiggle)) {
            float spd = vel.length();
            if (spd > 1e-4f) {
                Vec2 perp = Vec2{vel.y / spd, -vel.x / spd};
                float phaseMul = (spawnerType == 912) ? 2.0f : 1.0f;
                float phase = (static_cast<float>(wiggleOff) + curAge) * phaseMul * kTwoPi / 30.0f;
                float amp = (flags & IsaacEnums::kProjMegaWiggle)
                    ? (3.0f + std::sqrt(std::max(0.0f, 0.04f * (wiggleOff + curAge))))
                    : 3.0f;
                nextPos += perp * (std::sin(phase) * amp * 0.5f);
            }
        }

        // TURN_HORIZONTAL (1<<20): snaps to horizontal dash when vertically aligned with target
        if ((flags & IsaacEnums::kProjTurnHorizontal) && std::abs(nextPos.y - targetPos.y) < 12.0f) {
            float spd = std::max(vel.length() * 1.3f, 8.0f);
            vel = Vec2{(targetPos.x >= nextPos.x) ? spd : -spd, 0.0f};
        }

        // Gravity / Height from 0x65a26c
        float nextFs = std::pow(0.9f, dt) * fallSpeed + (0.1f + fallAccel) * dt;
        float nextH = height + nextFs * dt;

        // Bounce or land at -5.0f
        if (nextH > -5.0f) {
            if ((flags & IsaacEnums::kProjBounceFloor) && nextFs > 2.0f) {
                nextH = -5.0f;
                nextFs = -nextFs * 0.65f;
            } else {
                landed = true;
            }
        }
        if (scene.grid.beast && vel.y > 0.0f && nextPos.y > scene.grid.beastGroundY) {
            landed = true;
        }

        if (continuum) {
            float w = scene.grid.bottomRight.x - scene.grid.topLeft.x;
            float h = scene.grid.bottomRight.y - scene.grid.topLeft.y;
            if (w > 40.0f) {
                while (nextPos.x < scene.grid.topLeft.x) nextPos.x += w;
                while (nextPos.x > scene.grid.bottomRight.x) nextPos.x -= w;
            }
            if (h > 40.0f) {
                while (nextPos.y < scene.grid.topLeft.y) nextPos.y += h;
                while (nextPos.y > scene.grid.bottomRight.y) nextPos.y -= h;
            }
        } else if (!noWallCollide && !scene.grid.beast) {
            int gidx = scene.grid.indexAt(nextPos.x, nextPos.y);
            if (!scene.grid.inBoundsPoint(nextPos.x, nextPos.y, 0.0f) ||
                (gidx >= 0 && (scene.grid.cells[gidx] & RoomGrid::kSolidFly))) {
                // Obstacles block flying projectiles unless BOOMERANG / NO_WALL_COLLIDE
                if ((flags & IsaacEnums::kProjBounce) && gidx >= 0) {
                    vel = vel * -0.9f;
                } else {
                    landed = true;
                }
            }
        }

        track.pts[k] = nextPos;
        track.minX = std::min(track.minX, nextPos.x);
        track.maxX = std::max(track.maxX, nextPos.x);
        track.minY = std::min(track.minY, nextPos.y);
        track.maxY = std::max(track.maxY, nextPos.y);

        // Swept height collision band [-50 .. +1e9] or ANY_HEIGHT
        bool heightActive = anyHeight || (std::max(prevH, nextH) >= -50.0f && std::min(prevH, nextH) <= 20.0f);
        if (heightActive) {
            if (track.lastStep < 0) track.firstStep = k;
            track.lastStep = k;
        }

        pos = nextPos;
        fallSpeed = nextFs;
        prevH = height;
        height = nextH;
    }

    // If an explosive projectile lands or bursts before horizon, add its blast radius
    if (landed && (flags & IsaacEnums::kProjExplode) && track.lastStep > 0 && discs.size() < 384) {
        float tImpact = static_cast<float>(track.lastStep) * 0.5f;
        Vec2 impPos = track.pts[track.lastStep];
        discs.push_back(DiscHazard{impPos, {0.0f, 0.0f}, 85.0f,
                                   std::max(0.0f, tImpact - 0.5f), tImpact + 2.0f, 0});
    }
}

inline void appendNpcIntentWarnings(const MemReader& mem, uintptr_t entAddr,
                                    const ThreatScene& scene, float horizonUpdates,
                                    std::vector<DiscHazard>& discs,
                                    std::vector<LaserHazard>& lasers) {
    int type = 0, variant = 0, state = 0, stateFrame = 0, projCd = 0, projDelay = 0, i1 = 0;
    Vec2 pos{}, vel{}, sprOff{};
    float size = 13.0f, hp = 10.0f;
    mem.read(entAddr + Offsets::Entity::kType, type);
    mem.read(entAddr + Offsets::Entity::kVariant, variant);
    mem.read(entAddr + Offsets::Entity::kPos, pos);
    mem.read(entAddr + Offsets::Entity::kVel, vel);
    mem.read(entAddr + Offsets::Entity::kSize, size);
    mem.read(entAddr + Offsets::Entity::kHitPoints, hp);
    mem.read(entAddr + Offsets::Entity::kSpriteOffset, sprOff);
    mem.read(entAddr + Offsets::NPC::kState, state);
    mem.read(entAddr + Offsets::NPC::kStateFrame, stateFrame);
    mem.read(entAddr + Offsets::NPC::kProjCd, projCd);
    mem.read(entAddr + Offsets::NPC::kProjDelay, projDelay);
    mem.read(entAddr + Offsets::NPC::kI1, i1);

    char anim[64];
    float frame = 0.0f;
    bool playing = false, flipX = false;
    readSpriteState(mem, entAddr + Offsets::Entity::kSprite, anim, sizeof(anim), frame, playing, flipX);

    float roomDiag = (scene.grid.bottomRight - scene.grid.topLeft).length();
    if (roomDiag < 200.0f) roomDiag = 800.0f;

    // 1. Mom door arm ("ArmOpen" frame 7..12)
    if (type == IsaacEnums::kEntMom && variant == 0 && std::strcmp(anim, "ArmOpen") == 0 && frame <= 12.5f) {
        Vec2 center = (scene.grid.topLeft + scene.grid.bottomRight) * 0.5f;
        Vec2 inward = (center - pos).normalized();
        if (inward.lengthSq() > 0.5f) {
            static constexpr float kArmDist[3] = {15.0f, 40.0f, 62.0f};
            static constexpr float kArmRad[3]  = {24.0f, 24.0f, 30.0f};
            float from = std::max(0.0f, 6.0f - frame);
            float to   = std::max(0.5f, 12.5f - frame);
            for (int k = 0; k < 3; ++k) {
                discs.push_back(DiscHazard{pos + inward * kArmDist[k], {0, 0}, kArmRad[k], from, to, 0});
            }
        }
    }

    // 2. Wormwood (62.3) "Attack2" surface at frame 8
    if (type == IsaacEnums::kEntPin && variant == 3 && std::strcmp(anim, "Attack2") == 0 && frame <= 8.5f) {
        discs.push_back(DiscHazard{pos, {0, 0}, size + 3.0f,
            std::max(0.0f, 7.0f - frame), std::max(0.5f, 9.0f - frame), 0});
    }

    // 3. Satan stomp (84.10) "Stomp" frames 25..27
    if (type == IsaacEnums::kEntSatan && variant == 10 && std::strcmp(anim, "Stomp") == 0 && frame <= 27.5f) {
        discs.push_back(DiscHazard{pos, {0, 0}, size + 15.0f,
            std::max(0.0f, 24.0f - frame), std::max(0.5f, 28.0f - frame), 0});
    }

    // 4. Grudge (877) cardinal charge lane when stationary
    if (type == IsaacEnums::kEntGrudge && vel.lengthSq() < 1.0f) {
        static constexpr float kAxX[4] = {-1, 1, 0, 0};
        static constexpr float kAxY[4] = {0, 0, -1, 1};
        float halfW = std::max(16.0f, size + 4.0f);
        for (int a = 0; a < 4; ++a) {
            Vec2 dir{kAxX[a], kAxY[a]};
            float reach = 520.0f;
            for (float s = 40.0f; s <= 520.0f; s += 40.0f) {
                if (!scene.grid.inBoundsPoint(pos.x + dir.x * s, pos.y + dir.y * s, 0.0f)) {
                    reach = s; break;
                }
            }
            if (reach >= 40.0f) {
                addDirectedLaser(lasers, pos, {0, 0}, a == 0 ? 180.0f : (a == 1 ? 0.0f : (a == 2 ? 270.0f : 90.0f)),
                                 reach, halfW, 0.0f, true);
            }
        }
    }

    // 5. Pon (840) & Mother (912) leap/dash warnings
    if (type == IsaacEnums::kEntPon) {
        if (vel.lengthSq() > 16.0f || sprOff.y < -2.0f ||
            strContainsCI(anim, "jump") || strContainsCI(anim, "hop") || strContainsCI(anim, "attack")) {
            discs.push_back(DiscHazard{pos + vel * 1.5f, vel, size + 22.0f, 0.0f, horizonUpdates, 1});
        }
    } else if (type == IsaacEnums::kEntMother) {
        if (strContainsCI(anim, "dash") || strContainsCI(anim, "charge")) {
            Vec2 dir = vel.lengthSq() > 1.0f ? vel.normalized() : Vec2{0.0f, 1.0f};
            for (float d = 40.0f; d <= 200.0f; d += 45.0f) {
                discs.push_back(DiscHazard{pos + dir * d, vel * 0.25f, std::max(36.0f, size + 8.0f), 0.0f, horizonUpdates, 1});
            }
        } else if (strContainsCI(anim, "slam") || strContainsCI(anim, "fist") ||
                   strContainsCI(anim, "knife") || strContainsCI(anim, "spin")) {
            discs.push_back(DiscHazard{pos, vel, std::max(48.0f, size + 20.0f), 0.0f, horizonUpdates, 1});
        }
    }

    // 6. Airborne jump / stomp cue (sprOff.y < -5 or jump/land/stomp anim)
    if (sprOff.y < -5.0f || strContainsCI(anim, "jump") || strContainsCI(anim, "land") || strContainsCI(anim, "stomp")) {
        discs.push_back(DiscHazard{pos, vel * 0.35f, size + 25.0f, 0.0f, horizonUpdates, 1});
    }

    // 7. Exploder low-HP death burst warning
    if (isExploderNpc(type, variant)) {
        float burstR = (type == IsaacEnums::kEntBoomFly && variant == 6) ? 100.0f : 75.0f;
        if (hp <= std::max(3.5f, scene.player.tearDamage * 2.0f) || isChaserExploder(type, variant)) {
            discs.push_back(DiscHazard{pos, vel, burstR, 0.0f, horizonUpdates, 1});
            if (type == IsaacEnums::kEntBoomFly && variant == 6) {
                for (float ang : {0.0f, 90.0f, 180.0f, 270.0f}) {
                    addDirectedLaser(lasers, pos, vel, ang, 600.0f, 24.0f, 2.0f, true);
                }
            }
        }
    }

    // 8. Brimstone / Boss Laser Windups (exact parity with laser_hazards.lua + Sprite.FlipX Dogma fix)
    auto addCardStr = [&](const char* side, Vec2 org, float w, float trigFrame, bool warnOnly) {
        float af = std::max(0.5f, trigFrame - frame);
        if (std::strcmp(side, "Horiz") == 0) {
            addDirectedLaser(lasers, org, vel, 0.0f, roomDiag, w, af, warnOnly);
            addDirectedLaser(lasers, org, vel, 180.0f, roomDiag, w, af, warnOnly);
        } else if (std::strcmp(side, "Left") == 0) {
            addDirectedLaser(lasers, org, vel, 180.0f, roomDiag, w, af, warnOnly);
        } else if (std::strcmp(side, "Right") == 0) {
            addDirectedLaser(lasers, org, vel, 0.0f, roomDiag, w, af, warnOnly);
        } else if (std::strcmp(side, "Up") == 0) {
            addDirectedLaser(lasers, org, vel, 270.0f, roomDiag, w, af, warnOnly);
        } else if (std::strcmp(side, "Down") == 0) {
            addDirectedLaser(lasers, org, vel, 90.0f, roomDiag, w, af, warnOnly);
        }
    };

    if ((type == IsaacEnums::kEntVis && variant != 2) || type == IsaacEnums::kEntGluttony) {
        if (strStartsWith(anim, "Attack01")) addCardStr(anim + 8, pos, 18.0f, 27.0f, false);
        else if (variant == 1 && strStartsWith(anim, "Attack02")) addCardStr(anim + 8, pos, 18.0f, 31.0f, false);
    } else if (type == IsaacEnums::kEntRageCreep && std::strcmp(anim, "Attack") == 0) {
        float gap = pos.x - scene.grid.topLeft.x;
        float ang = 0.0f;
        if (scene.grid.bottomRight.x - pos.x < gap) { ang = 180.0f; gap = scene.grid.bottomRight.x - pos.x; }
        if (pos.y - scene.grid.topLeft.y < gap) { ang = 90.0f; gap = pos.y - scene.grid.topLeft.y; }
        if (scene.grid.bottomRight.y - pos.y < gap) { ang = 270.0f; }
        addDirectedLaser(lasers, pos, vel, ang, roomDiag, 18.0f, std::max(0.5f, 15.0f - frame), false);
    } else if (type == IsaacEnums::kEntMonstro2 && std::strcmp(anim, "Taunt") == 0) {
        addDirectedLaser(lasers, pos, vel, 0.0f, roomDiag, 24.0f, std::max(0.5f, 20.0f - frame), false);
        addDirectedLaser(lasers, pos, vel, 180.0f, roomDiag, 24.0f, std::max(0.5f, 20.0f - frame), false);
    } else if (type == IsaacEnums::kEntDarkOne && std::strcmp(anim, "Attack2") == 0) {
        addDirectedLaser(lasers, pos, vel, 90.0f, roomDiag, 24.0f, std::max(0.5f, 19.0f - frame), false);
    } else if (type == IsaacEnums::kEntTheHaunt && std::strcmp(anim, "LaserNoSkin") == 0) {
        addDirectedLaser(lasers, pos, vel, 90.0f, roomDiag, 24.0f, std::max(0.5f, 16.0f - frame), false);
    } else if (type == IsaacEnums::kEntSatan && variant == 0 && std::strcmp(anim, "Attack02") == 0) {
        addDirectedLaser(lasers, pos, vel, 90.0f, roomDiag, 24.0f, std::max(0.5f, 20.0f - frame), false);
    } else if (type == IsaacEnums::kEntMegaSatan && variant == 0 && std::strcmp(anim, "Shoot1") == 0) {
        addDirectedLaser(lasers, pos, vel, 90.0f, roomDiag, 36.0f, std::max(0.5f, 4.0f - frame), false);
    } else if (type == IsaacEnums::kEntFallen && variant == 1 && std::strcmp(anim, "Attack2Alt") == 0) {
        for (float ang : {0.0f, 90.0f, 180.0f, 270.0f}) {
            addDirectedLaser(lasers, pos, vel, ang, roomDiag, 24.0f, std::max(0.5f, 29.0f - frame), false);
        }
    } else if (type == IsaacEnums::kEntEye && (variant == 0 || variant == 1) && std::strcmp(anim, "Shoot") == 0) {
        Vec2 toP = scene.player.pos - pos;
        float ang = std::atan2(toP.y, toP.x) * 57.2957795f;
        addDirectedLaser(lasers, pos, vel, ang, roomDiag, variant == 0 ? 12.0f : 24.0f,
                         std::max(0.5f, 10.0f - frame), false);
    } else if (type == IsaacEnums::kEntRedGhost && strStartsWith(anim, "Shoot")) {
        addCardStr(anim + 5, pos, 24.0f, 13.0f, false);
    } else if (type == IsaacEnums::kEntDogma && variant == 0) {
        Vec2 org{pos.x, pos.y - 15.0f};
        if (strStartsWith(anim, "BrimstoneStart")) {
            float af = std::max(0.5f, 39.0f - frame);
            const char* side = anim + 14;
            if (std::strcmp(side, "Right") == 0 || std::strcmp(side, "Left") == 0) {
                float ang = (std::strcmp(side, "Right") == 0) ? (flipX ? 180.0f : 0.0f)
                                                              : (flipX ? 0.0f : 180.0f);
                addDirectedLaser(lasers, org, vel, ang, roomDiag, 24.0f, af, false);
            } else {
                addCardStr(side, org, 24.0f, 39.0f, false);
            }
        } else if (strStartsWith(anim, "BrimstoneLoop")) {
            Vec2 toP = scene.player.pos - org;
            float ang = (std::abs(toP.x) >= std::abs(toP.y)) ? (toP.x >= 0 ? 0.0f : 180.0f)
                                                             : (toP.y >= 0 ? 90.0f : 270.0f);
            addDirectedLaser(lasers, org, vel, ang, roomDiag, 20.0f, 1.5f, true);
        }
    } else if ((type == IsaacEnums::kEntUriel || type == IsaacEnums::kEntGabriel) &&
               (state == 9 || state == 10)) {
        float af = 0.0f;
        bool ok = false;
        if (std::strcmp(anim, "Charging") == 0 || std::strcmp(anim, "Charging2") == 0) {
            af = (i1 == 0) ? std::max(0.5f, static_cast<float>(29 - stateFrame)) : 3.0f;
            ok = true;
        } else if (std::strcmp(anim, "LaserShot") == 0 && frame < 4.0f) {
            af = std::max(0.5f, 4.0f - frame);
            ok = true;
        }
        if (ok) {
            bool diag = (state == 10);
            if (type == IsaacEnums::kEntUriel) {
                if (diag) {
                    for (float ang : {45.0f, 135.0f}) {
                        addDirectedLaser(lasers, {pos.x, pos.y + 5.0f}, vel, ang, roomDiag, 18.0f, af, true);
                    }
                } else {
                    addDirectedLaser(lasers, {pos.x, pos.y + 5.0f}, vel, 90.0f, roomDiag, 18.0f, af, true);
                }
            } else {
                const float cands[4] = {diag ? 45.0f : 0.0f, diag ? 135.0f : 90.0f,
                                        diag ? 225.0f : 180.0f, diag ? 315.0f : 270.0f};
                for (float ang : cands) {
                    Vec2 d = Vec2{1.0f, 0.0f}.rotatedDeg(ang);
                    addDirectedLaser(lasers, pos + d * 7.0f, vel, ang, roomDiag, 18.0f, af, true);
                }
            }
        }
    }

    // 9. ProjectileCooldown / ProjectileDelay telegraphing for imminent shots
    // When an active shooter is within 1..3 updates of firing with clear LoS to player,
    // place a soft warning beam along its line of fire so the planner steps off early.
    int windup = 0;
    if (projDelay > 0 && projDelay <= 3) windup = projDelay;
    else if (projCd > 0 && projCd <= 3 && (state == 8 || state == 9 || state == 10)) windup = projCd;
    if (windup > 0) {
        Vec2 toP = scene.player.pos - pos;
        float dist = toP.length();
        if (dist > 25.0f && dist < 380.0f && scene.grid.lineClear(pos, scene.player.pos)) {
            float ang = std::atan2(toP.y, toP.x) * 57.2957795f;
            float reach = std::min(dist + 70.0f, 240.0f);
            addDirectedLaser(lasers, pos, vel * 0.25f, ang, reach, 10.0f,
                             static_cast<float>(windup), true);
        }
    }
}

} // namespace detail

// Populate `scene` completely read-only from game memory. Returns true if valid and active.
inline bool collectThreatScene(const MemReader& mem, uintptr_t imageBase,
                               uint32_t boundSeed, uint32_t luaFlags,
                               int horizonMs, int queueDelay, int steps60Cap,
                               ThreatScene& scene) {
    scene.clear();
    if (!imageBase || boundSeed == 0) return false;

    uintptr_t mgr  = mem.readPtr32(imageBase + Offsets::kManagerRva);
    uintptr_t game = mem.readPtr32(imageBase + Offsets::kGameRva);
    if (!mgr || !game) return false;

    int mgrState = 0;
    uint32_t tick60 = 0;
    if (!mem.read(mgr + Offsets::Manager::kState, mgrState) || mgrState != 2) return false;
    mem.read(mgr + Offsets::Manager::kTick60, tick60);
    scene.tick60 = tick60;

    // Paused / transition checks matching Game::IsPaused (0x6fd350) + Lua pause flag
    if (luaFlags & Shared::kFlagPaused) { scene.paused = true; return false; }
    int32_t pFrames = 0, p68 = 0, pb8 = 0, pba = 0, pd5 = 0, pd6 = 0, pc0 = 0;
    uint8_t p25 = 0;
    mem.read(game + Offsets::Game::kPauseFrames, pFrames);
    mem.read(game + Offsets::Game::kPause68D78, p68);
    mem.read(game + Offsets::Game::kPauseB83C, pb8);
    mem.read(game + Offsets::Game::kPauseBA78, pba);
    mem.read(game + Offsets::Game::kPauseD520, pd5);
    mem.read(game + Offsets::Game::kPauseD654, pd6);
    mem.read(game + Offsets::Game::kPauseC034, pc0);
    mem.read(game + Offsets::Game::kPause25954, p25);
    if (pFrames > 0 || pb8 || pba || pd5 || pd6 || pc0 == 2 || p25) {
        scene.paused = true;
        return false;
    }

    mem.read(game + Offsets::Game::kFrameCount, scene.frameCount30);
    uintptr_t room = mem.readPtr32(game + Offsets::Game::kRoom);
    if (!room) return false;

    // Locate our exact player strictly by boundSeed
    uintptr_t playersBegin = mem.readPtr32(game + Offsets::Game::kPlayersBegin);
    uintptr_t playersEnd   = mem.readPtr32(game + Offsets::Game::kPlayersEnd);
    if (!playersBegin || playersEnd < playersBegin) return false;
    size_t playerCount = (playersEnd - playersBegin) / 4u;
    if (playerCount == 0 || playerCount > 16) return false;

    uintptr_t myPlayer = 0;
    for (size_t i = 0; i < playerCount; ++i) {
        uintptr_t pPtr = mem.readPtr32(playersBegin + i * 4u);
        if (!pPtr) continue;
        uint32_t seed = 0;
        if (mem.read(pPtr + Offsets::Entity::kInitSeed, seed) && seed == boundSeed) {
            myPlayer = pPtr;
            break;
        }
    }
    if (!myPlayer) return false;

    uint8_t dead = 0, ghost = 0, canFly = 0, ctrlEn = 1;
    int playerType = 0, subSlot = 0, ctrlCd = 0, ctrlIdx = 0;
    mem.read(myPlayer + Offsets::Entity::kDead, dead);
    mem.read(myPlayer + Offsets::Player::kIsCoopGhost, ghost);
    mem.read(myPlayer + Offsets::Player::kPlayerType, playerType);
    mem.read(myPlayer + Offsets::Player::kSubPlayerSlot, subSlot);
    mem.read(myPlayer + Offsets::Player::kControlsEnabled, ctrlEn);
    mem.read(myPlayer + Offsets::Player::kControlsCooldown, ctrlCd);
    mem.read(myPlayer + Offsets::Player::kControllerIndex, ctrlIdx);
    mem.read(myPlayer + Offsets::Player::kCanFly, canFly);
    uintptr_t subPtr = mem.readPtr32(myPlayer + Offsets::Player::kSubPlayer);
    if (dead || ghost || subPtr || subSlot < 0 || detail::unsupportedPlayerType(playerType)) {
        return false;
    }

    scene.player.ptr = myPlayer;
    scene.player.initSeed = boundSeed;
    scene.player.canFly = (canFly != 0);
    scene.player.controllerIndex = ctrlIdx;
    mem.read(myPlayer + Offsets::Entity::kPos, scene.player.pos);
    mem.read(myPlayer + Offsets::Entity::kVel, scene.player.vel);
    mem.read(myPlayer + Offsets::Entity::kSize, scene.player.size);
    mem.read(myPlayer + Offsets::Player::kMoveSpeed, scene.player.moveSpeed);
    mem.read(myPlayer + Offsets::Player::kMaxFireDelay, scene.player.effectiveMaxFireDelay);
    uint64_t pFlags = 0;
    mem.read(myPlayer + Offsets::Entity::kFlags, pFlags);
    scene.player.slippery = (pFlags & IsaacEnums::kEntFlagSlippery) != 0;
    if (!std::isfinite(scene.player.pos.x) || !std::isfinite(scene.player.pos.y)) return false;
    scene.player.size = std::max(4.0f, std::min(40.0f, scene.player.size));
    scene.player.moveSpeed = std::max(0.1f, std::min(2.5f, scene.player.moveSpeed));

    // Read room geometry & descriptor
    RoomGrid& g = scene.grid;
    mem.read(room + Offsets::Room::kType, g.type);
    mem.read(room + Offsets::Room::kGridWidth, g.width);
    mem.read(room + Offsets::Room::kGridHeight, g.height);
    mem.read(room + Offsets::Room::kTopLeft, g.topLeft);
    mem.read(room + Offsets::Room::kBottomRight, g.bottomRight);
    if (g.width <= 0 || g.height <= 0 || g.width > 30 || g.height > 30) return false;
    g.cellCount = std::min(Offsets::Room::kMaxGridCells, g.width * g.height);

    uintptr_t desc = mem.readPtr32(room + Offsets::Room::kDescriptor);
    uintptr_t descData = desc ? mem.readPtr32(desc + Offsets::Room::kDescData) : 0;
    int stageId = 0, dataType = 0;
    if (descData) {
        mem.read(descData + Offsets::Room::kDataStageId, stageId);
        mem.read(descData + Offsets::Room::kDataType, dataType);
        mem.read(descData + Offsets::Room::kDataShape, g.shape);
    }

    int dim = 0, stage = 0, stageType = 0;
    uint32_t curses = 0;
    mem.read(game + Offsets::Game::kDimension, dim);
    mem.read(game + Offsets::Game::kStage, stage);
    mem.read(game + Offsets::Game::kStageType, stageType);
    mem.read(game + Offsets::Game::kCurses, curses);
    bool engineMirror = (dim == 1 && (stageType == 4 || stageType == 5) &&
                         (stage == 2 || (stage == 1 && (curses & 2u))));
    g.mirror = engineMirror || ((luaFlags & Shared::kFlagMirror) != 0);
    g.beast = (dataType == 16 && stageId == 35) || ((luaFlags & Shared::kFlagBeastRoom) != 0);
    g.beastGroundY = g.bottomRight.y - 30.0f;
    scene.deathmatch = (g.type == 30 || dataType == 30 || (luaFlags & Shared::kFlagDeathmatch) != 0);

    // Derive grid pitch/origin cleanly from TopLeft/BottomRight (matches 40x40 grid)
    g.pitch = {40.0f, 40.0f};
    g.origin = {g.topLeft.x - 20.0f, g.topLeft.y - 20.0f};

    // Populate room grid cell hazards
    g.cells.fill(0);
    for (int i = 0; i < g.cellCount; ++i) {
        uintptr_t ge = mem.readPtr32(room + Offsets::Room::kGridEntities + static_cast<uintptr_t>(i) * 4u);
        uint8_t cf = 0;
        if (ge) {
            int gt = 0, gv = 0, gs = 0, gc = 0;
            mem.read(ge + Offsets::Grid::kType, gt);
            mem.read(ge + Offsets::Grid::kVariant, gv);
            mem.read(ge + Offsets::Grid::kState, gs);
            mem.read(ge + Offsets::Grid::kCollisionClass, gc);
            if (gc == IsaacEnums::kGridCollWall) {
                cf |= RoomGrid::kSolidGround | RoomGrid::kSolidFly;
            } else if (gc != IsaacEnums::kGridCollNone && gc != IsaacEnums::kGridCollWallExcept) {
                cf |= RoomGrid::kSolidGround;
                if (gc == IsaacEnums::kGridCollSolid && gt == IsaacEnums::kGridLock) {
                    cf |= RoomGrid::kSolidFly;
                }
            }
            if (gt == IsaacEnums::kGridSpikes || gt == IsaacEnums::kGridSpikesOnOff) {
                bool active = true;
                if (gt == IsaacEnums::kGridSpikesOnOff && gs == 1) active = false;
                if (active) {
                    char spAnim[32];
                    float spFrame = 0.0f;
                    bool spPlay = false, spFx = false;
                    if (detail::readSpriteState(mem, ge + Offsets::Grid::kSprite, spAnim, sizeof(spAnim),
                                                spFrame, spPlay, spFx)) {
                        if (detail::strStartsWith(spAnim, "Unsummon") && (!spPlay || spFrame >= 11.0f)) {
                            active = false;
                        }
                    }
                }
                if (active) cf |= RoomGrid::kHazard;
            } else if (gt == IsaacEnums::kGridPoop && gv == 1 && gs != 1000) {
                cf |= RoomGrid::kHazard;
            }
        } else {
            int raw = 0;
            mem.read(room + Offsets::Room::kGridRawTypes + static_cast<uintptr_t>(i) * 4u, raw);
            if (raw >= 3000 && raw <= 3999) {
                cf |= RoomGrid::kSolidGround; // COLLISION_PIT
            } else if (raw >= 1000) {
                cf |= RoomGrid::kSolidGround; // COLLISION_SOLID
            }
        }
        g.cells[i] = cf;
    }

    if (g.beast) {
        for (float mx = 120.0f; mx <= 680.0f; mx += 80.0f) {
            scene.discs.push_back(DiscHazard{{mx, 500.0f}, {0, 0}, 60.0f, 0.0f, 1e6f, 0});
        }
    }

    int hMs = std::max(150, std::min(700, horizonMs > 0 ? horizonMs : 450));
    float horizonUpdates = static_cast<float>(hMs) / 33.333333f;
    int steps60 = std::max(10, std::min(steps60Cap, static_cast<int>(std::ceil(horizonUpdates * 2.0f))));
    scene.steps60 = steps60;
    scene.queueDelay30 = std::max(0, std::min(8, queueDelay));

    // Read Room EntityList (+0x125c data*, +0x1264 count)
    uintptr_t entData = mem.readPtr32(room + Offsets::Room::kEntityData);
    uint32_t entCount = 0;
    mem.read(room + Offsets::Room::kEntityCount, entCount);
    entCount = std::min<uint32_t>(entCount, 1024u);

    struct BombInfo {
        Vec2 pos, vel;
        float size = 10.0f;
        float radiusMult = 1.0f;
        float atUpdates = 0.0f;
        float friction = 0.95f;
        Vec2 blastPos;
        Vec2 sweep{0, 0};
        bool pushed = false;
    };
    std::vector<BombInfo> bombs;
    bombs.reserve(16);

    float maxReach = 6.5f * scene.player.moveSpeed * horizonUpdates + scene.player.size + 160.0f;

    for (uint32_t ei = 0; ei < entCount && entData; ++ei) {
        uintptr_t e = mem.readPtr32(entData + static_cast<uintptr_t>(ei) * 4u);
        if (!e || e == myPlayer) continue;

        uint8_t exists = 0, eDead = 0;
        int eType = 0, eVar = 0, eSub = 0, eEntityColl = 0;
        uint64_t eFlags = 0;
        float eSize = 10.0f, eCollDmg = 0.0f;
        Vec2 ePos{}, eVel{};
        mem.read(e + Offsets::Entity::kExists, exists);
        mem.read(e + Offsets::Entity::kDead, eDead);
        mem.read(e + Offsets::Entity::kType, eType);
        if (!exists) continue;
        mem.read(e + Offsets::Entity::kVariant, eVar);
        mem.read(e + Offsets::Entity::kSubType, eSub);
        mem.read(e + Offsets::Entity::kFlags, eFlags);
        mem.read(e + Offsets::Entity::kEntityColl, eEntityColl);
        mem.read(e + Offsets::Entity::kPos, ePos);
        mem.read(e + Offsets::Entity::kVel, eVel);
        mem.read(e + Offsets::Entity::kSize, eSize);
        mem.read(e + Offsets::Entity::kCollDamage, eCollDmg);
        if (!std::isfinite(ePos.x) || !std::isfinite(ePos.y)) continue;

        if (eType == IsaacEnums::kEntProjectile) {
            if (eDead) continue;
            if (!scene.deathmatch && detail::isPlayerOwned(mem, e, false, boundSeed)) continue;
            if (scene.bullets.size() < 256) {
                BulletTrack tr{};
                detail::simulateProjectile(mem, e, scene, horizonUpdates, steps60, tr, scene.discs);
                if (tr.lastStep >= tr.firstStep && tr.lastStep >= 0) scene.bullets.push_back(tr);
            }
            continue;
        }

        if (eType == IsaacEnums::kEntLaser) {
            if (eDead || detail::isPlayerOwned(mem, e, scene.deathmatch, boundSeed)) continue;
            if (scene.lasers.size() >= 64) continue;
            LaserHazard lh{};
            lh.origin = ePos;
            lh.vel = eVel;
            uint8_t disableFollow = 0, isRot = 0;
            mem.read(e + Offsets::Laser::kDisableFollowParent, disableFollow);
            mem.read(e + Offsets::Laser::kIsActiveRotating, isRot);
            uintptr_t parent = mem.readPtr32(e + Offsets::Entity::kParent);
            bool parentNpc = false;
            if (parent && !disableFollow) {
                Vec2 pVel{};
                int pt = 0;
                mem.read(parent + Offsets::Entity::kType, pt);
                parentNpc = (pt >= 10 && pt <= 999);
                if (mem.read(parent + Offsets::Entity::kVel, pVel) && std::isfinite(pVel.x)) {
                    lh.vel = pVel;
                }
            }
            lh.ring = (eSub == 1 || eSub == 2 || eSub == 3);
            mem.read(e + Offsets::Laser::kRadius, lh.radius);
            lh.width = std::max(8.0f, eSize) + 4.0f;
            if (isRot) {
                int rDel = 0;
                mem.read(e + Offsets::Laser::kRotationSpd, lh.angularSpeed);
                mem.read(e + Offsets::Laser::kRotationDelay, rDel);
                lh.rotDelay = static_cast<float>(std::max(0, rDel));
            }
            if (!lh.ring) {
                uintptr_t sb = mem.readPtr32(e + Offsets::Laser::kSamplesBegin);
                uintptr_t se = mem.readPtr32(e + Offsets::Laser::kSamplesEnd);
                if (sb && se >= sb) {
                    size_t cnt = std::min<size_t>(LaserHazard::kMaxSamples, (se - sb) / sizeof(Vec2));
                    for (size_t s = 0; s < cnt; ++s) {
                        Vec2 pt{};
                        if (mem.read(sb + s * sizeof(Vec2), pt) && std::isfinite(pt.x)) {
                            Vec2 rel = pt - lh.origin;
                            lh.pts[lh.numPts++] = rel;
                            lh.reach = std::max(lh.reach, rel.length());
                        }
                    }
                }
                if (lh.numPts < 2) {
                    Vec2 ep{};
                    mem.read(e + Offsets::Laser::kEndPoint, ep);
                    lh.numPts = 2;
                    lh.pts[0] = {0.0f, 0.0f};
                    lh.pts[1] = ep - lh.origin;
                    lh.reach = lh.pts[1].length();
                }
            }
            scene.lasers.push_back(lh);
            if (parentNpc && !lh.ring) {
                LaserHazard band = lh;
                band.width += 24.0f;
                band.warning = 1;
                scene.lasers.push_back(band);
            }
            continue;
        }

        if (eType == IsaacEnums::kEntBomb) {
            if (eDead) continue;
            float dmg = 0.0f, mult = 1.0f;
            mem.read(e + Offsets::Bomb::kExplosionDamage, dmg);
            mem.read(e + Offsets::Bomb::kRadiusMultiplier, mult);
            if (dmg <= 0.0f) continue;
            char bAnim[32];
            float bFrame = 0.0f;
            bool bPlay = false, bFx = false;
            float at = -1.0f;
            if (detail::readSpriteState(mem, e + Offsets::Entity::kSprite, bAnim, sizeof(bAnim), bFrame, bPlay, bFx)) {
                if (std::strcmp(bAnim, "Pulse") == 0 && bFrame <= 59.0f) {
                    at = std::max(0.0f, 58.0f - bFrame);
                }
            }
            if (at < 0.0f) {
                int32_t cd = 0;
                mem.read(e + Offsets::Bomb::kExplosionCountdown, cd);
                if (cd > 0 && cd <= 120) at = static_cast<float>(cd);
            }
            if (at >= 0.0f && at <= horizonUpdates + 2.0f) {
                BombInfo bi{};
                bi.pos = ePos; bi.vel = eVel; bi.size = eSize;
                bi.radiusMult = std::max(0.5f, mult);
                bi.atUpdates = at;
                bi.friction = (eVar == 4) ? 1.0f : 0.95f; // BOMB_SUPERTROLL = 4
                float driftScale = (bi.friction >= 1.0f) ? at : (1.0f - std::pow(bi.friction, at)) / (1.0f - bi.friction);
                bi.blastPos = bi.pos + bi.vel * driftScale;
                bombs.push_back(bi);
            }
            // Rolling envelope warning for live bombs within reach
            if ((ePos - scene.player.pos).length() <= maxReach + 105.0f * std::max(0.5f, mult)) {
                scene.discs.push_back(DiscHazard{ePos, eVel * 0.5f, 100.0f * std::max(0.5f, mult),
                                                 0.0f, horizonUpdates, 1});
            }
            continue;
        }

        if (eType == IsaacEnums::kEntEffect) {
            if (eDead) continue;
            if (detail::isPlayerOwned(mem, e, scene.deathmatch, boundSeed)) continue;
            Vec2 sm{1.0f, 1.0f};
            int timeout = 0;
            mem.read(e + Offsets::Entity::kSizeMulti, sm);
            mem.read(e + Offsets::Effect::kTimeout, timeout);
            float maxT = (timeout > 0) ? std::min(horizonUpdates, static_cast<float>(timeout)) : horizonUpdates;
            if (detail::isEnemyCreepVariant(eVar)) {
                float r = std::max(8.0f, eSize * std::max(sm.x, sm.y));
                if ((ePos - scene.player.pos).length() <= maxReach + r) {
                    scene.discs.push_back(DiscHazard{ePos, {0, 0}, r, 0.0f, maxT, 0});
                }
            } else if (eVar == 110) { // ENEMY_BRIMSTONE_SWIRL
                char sAnim[32];
                float sFrame = 0.0f;
                bool sPlay = false, sFx = false;
                if (detail::readSpriteState(mem, e + Offsets::Entity::kSprite, sAnim, sizeof(sAnim), sFrame, sPlay, sFx) &&
                    std::strcmp(sAnim, "IdleQuick") == 0) {
                    float af = std::max(0.5f, 24.0f - sFrame);
                    float diag = std::max(600.0f, (g.bottomRight - g.topLeft).length());
                    for (float ang : {0.0f, 90.0f, 180.0f, 270.0f}) {
                        detail::addDirectedLaser(scene.lasers, ePos, eVel, ang, diag, 24.0f, af, false);
                    }
                }
            } else if (eVar == 19 || eVar == 28 || eVar == 29 || eVar == 61 ||
                       eVar == 67 || eVar == 71 || eVar == 72 || eVar == 73 ||
                       eVar == 91 || eVar == 183) {
                float r = std::max(16.0f, eSize * std::max(1.0f, sm.x));
                if ((ePos - scene.player.pos).length() <= maxReach + r) {
                    scene.discs.push_back(DiscHazard{ePos, eVel, r, 0.0f, maxT, 0});
                }
            }
            continue;
        }

        if (eType == IsaacEnums::kEntPickup) {
            int price = 0;
            mem.read(e + Offsets::Pickup::kPrice, price);
            if ((eVar == 100 && eSub != 0) || price != 0 || ((eVar == 52 || eVar == 54) && eSub != 0)) {
                int pidx = g.indexAt(ePos.x, ePos.y);
                if (pidx >= 0 && pidx < g.cellCount) {
                    g.cells[pidx] |= RoomGrid::kAutoAvoid;
                }
            }
            continue;
        }

        // Deathmatch enemy player or Active NPCs
        uint32_t initSeed = 0;
        mem.read(e + Offsets::Entity::kInitSeed, initSeed);
        if (eType == IsaacEnums::kEntPlayer) {
            if (scene.deathmatch && !eDead && initSeed != boundSeed) {
                scene.discs.push_back(DiscHazard{ePos, eVel, eSize + 3.0f, 0.0f, horizonUpdates, 0});
            }
            continue;
        }

        // Dead exploding NPCs (e.g. Tainted Boom Fly "Explode" animation)
        if (eDead && eType == IsaacEnums::kEntBoomFly) {
            char dAnim[32];
            float dFrame = 0.0f;
            bool dPlay = false, dFx = false;
            if (detail::readSpriteState(mem, e + Offsets::Entity::kSprite, dAnim, sizeof(dAnim), dFrame, dPlay, dFx) &&
                std::strcmp(dAnim, "Explode") == 0) {
                float r = (eVar == 6) ? 100.0f : 75.0f;
                float rem = std::max(0.5f, 30.0f - dFrame);
                scene.discs.push_back(DiscHazard{ePos, {0, 0}, r, 0.0f, rem, 0});
                if (eVar == 6) {
                    float cf = std::max(0.5f, 25.0f - dFrame);
                    for (float ang : {0.0f, 90.0f, 180.0f, 270.0f}) {
                        detail::addDirectedLaser(scene.lasers, ePos, {0, 0}, ang, 600.0f, 24.0f, cf, true);
                    }
                }
            }
            continue;
        }

        if (!detail::isActiveEnemyRaw(eType, eVar, eDead, eFlags, scene.deathmatch, initSeed, boundSeed)) {
            continue;
        }

        // Contact hazard if NPC can collide and deals collision damage (or always active contact body)
        if (eEntityColl != 0 && (eCollDmg > 0.0f || eSize >= 8.0f)) {
            if ((ePos - scene.player.pos).length() <= maxReach + eSize + eVel.length() * horizonUpdates) {
                scene.discs.push_back(DiscHazard{ePos, eVel, eSize + 3.0f, 0.0f, horizonUpdates, 0});
            }
        }

        detail::appendNpcIntentWarnings(mem, e, scene, horizonUpdates, scene.discs, scene.lasers);
    }

    // Bomb chain knockback resolution (sorted by detonation time)
    if (!bombs.empty()) {
        std::sort(bombs.begin(), bombs.end(), [](const BombInfo& a, const BombInfo& b) {
            return a.atUpdates < b.atUpdates;
        });
        size_t chainMax = std::min<size_t>(bombs.size(), 8);
        for (size_t i = 0; i < chainMax; ++i) {
            float br = 78.0f * bombs[i].radiusMult;
            Vec2 from = bombs[i].blastPos;
            Vec2 to = from + bombs[i].sweep;
            Vec2 seg = to - from;
            float segSq = seg.lengthSq();
            for (size_t j = i + 1; j < chainMax; ++j) {
                if (bombs[j].atUpdates <= bombs[i].atUpdates) continue;
                float dtB = std::max(0.0f, bombs[i].atUpdates);
                float ds = (bombs[j].friction >= 1.0f)
                    ? dtB
                    : (1.0f - std::pow(bombs[j].friction, dtB)) / (1.0f - bombs[j].friction);
                Vec2 where = bombs[j].pos + bombs[j].vel * ds + bombs[j].sweep;
                float u = (segSq > 1e-6f) ? std::max(0.0f, std::min(1.0f, (where - from).dot(seg) / segSq)) : 0.0f;
                Vec2 away = where - (from + seg * u);
                float slideUpdates = bombs[j].atUpdates - bombs[i].atUpdates - 1.0f;
                if (slideUpdates > 0.0f && away.length() <= br + bombs[j].size) {
                    float slideDist = 14.0f * (1.0f - std::pow(0.95f, slideUpdates)) / 0.05f;
                    if (away.lengthSq() < 1.0f) {
                        bombs[j].radiusMult += slideDist / 78.0f;
                    } else {
                        bombs[j].sweep += away.normalized() * slideDist;
                    }
                    bombs[j].pushed = true;
                }
            }
            float early = bombs[i].pushed ? 2.0f : 1.0f;
            float late = bombs[i].pushed ? 2.0f : 1.0f;
            scene.discs.push_back(DiscHazard{
                bombs[i].blastPos,
                bombs[i].sweep.lengthSq() > 0.01f ? bombs[i].sweep * (1.0f / std::max(1.0f, bombs[i].atUpdates)) : Vec2{0, 0},
                78.0f * bombs[i].radiusMult,
                std::max(0.0f, bombs[i].atUpdates - early),
                bombs[i].atUpdates + late,
                0
            });
        }
    }

    scene.valid = true;
    return true;
}

} // namespace iad
