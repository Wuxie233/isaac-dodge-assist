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
    static constexpr int kMaxPts = 64; // covers up to 30 updates (60 ticks @ 60Hz) incl. queueDelay + blastHorizon
    Vec2 pts[kMaxPts]{};               // pos at player step k (t = k * 0.5f)
    float radius = 0.0f;
    float minX = 0.0f, maxX = 0.0f, minY = 0.0f, maxY = 0.0f;
    int firstStep = 0;
    int lastStep = -1;
    uint8_t warning = 0;
};

struct DiscHazard {
    Vec2 pos;
    Vec2 vel;
    float radius = 0.0f;
    float fromT = 0.0f;
    float toT = 1e6f;
    uint8_t warning = 0;
    Vec2 sweepEndOffset{0.0f, 0.0f};
    bool isCapsule = false;  // segment [pos, pos + sweepEndOffset] (e.g. chain-pushed bomb blast)
    bool autoOnly = false;   // avoided only in AUTO mode (e.g. Sacrifice Room spikes)
    bool isEnemyBody = false;
    bool groundOnly = false; // hurts ground bodies (!canFly) only; flyers pass safely over
};

struct LaserHazard {
    static constexpr int kMaxSamples = 64;
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
        kSolidGround = 1 << 0, // blocks non-flying physical movement (rocks, pits, poop, pillars, walls)
        kSolidFly    = 1 << 1, // blocks flying physical movement (walls, pillars, key blocks)
        kPit         = 1 << 2, // pit tile (ground-solid, projectiles fly over)
        kAutoAvoid   = 1 << 3, // pedestals, priced shop items, mimic/spiked chests, sacrifice spikes
    };

    int width = 15;
    int height = 9;
    int cellCount = 135;
    int shape = 1;
    int type = 1;
    bool beast = false;
    bool mirror = false;
    bool hasSolidCells = false;
    Vec2 topLeft{60.0f, 140.0f};
    Vec2 bottomRight{580.0f, 420.0f};
    Vec2 pitch{40.0f, 40.0f};
    Vec2 origin{40.0f, 120.0f}; // Fixed world grid origin (0x7f24a4), invariant even in narrow shapes 2/3/5/7
    float beastGroundY = 420.0f;
    std::array<uint8_t, Offsets::Room::kMaxGridCells> cells{};

    bool isLShape() const { return shape >= 9 && shape <= 12; }

    Vec2 cellCenter(int idx) const {
        int col = idx % width;
        int row = idx / width;
        return {origin.x + static_cast<float>(col) * pitch.x,
                origin.y + static_cast<float>(row) * pitch.y};
    }

    int indexAt(float x, float y) const {
        if (pitch.x <= 0.0f || pitch.y <= 0.0f) return -1;
        int col = static_cast<int>(std::floor((x - origin.x) / pitch.x + 0.5f));
        int row = static_cast<int>(std::floor((y - origin.y) / pitch.y + 0.5f));
        if (col < 0 || col >= width || row < 0 || row >= height) return -1;
        int idx = col + row * width;
        return (idx >= 0 && idx < cellCount) ? idx : -1;
    }

    // Positive depth inside an L-room's missing quadrant (plus margin), or <= 0 when outside the cutout.
    // Single source of truth for Room::GetClampedPosition (0x812f50) L-room geometry.
    float lRoomCutoutOverflow(float x, float y, float margin = 0.0f) const {
        if (!isLShape()) return 0.0f;
        // L-rooms are 28x16 grids spanning world [40..1120] x [120..720], interior [60..1100] x [140..700].
        float midX = (topLeft.x + bottomRight.x) * 0.5f;
        float midY = (topLeft.y + bottomRight.y) * 0.5f;
        bool cutLeft = (shape == 9 || shape == 11);
        bool cutTop  = (shape == 9 || shape == 10);
        float inX = cutLeft ? (midX + margin - x) : (x - (midX - margin));
        float inY = cutTop  ? (midY + margin - y) : (y - (midY - margin));
        if (inX <= 0.0f || inY <= 0.0f) return 0.0f;
        if (margin > 0.0f) {
            float rawX = cutLeft ? (midX - x) : (x - midX);
            float rawY = cutTop  ? (midY - y) : (y - midY);
            if (rawX < 0.0f && rawY < 0.0f) {
                float cornerSq = (-rawX) * (-rawX) + (-rawY) * (-rawY);
                if (cornerSq > margin * margin) return 0.0f;
                return margin - std::sqrt(cornerSq) + 1e-3f;
            }
        }
        return std::min(inX, inY);
    }

    // Distance to nearest wall (including L-room inner cutout walls).
    float wallClearance(float x, float y) const {
        float marginX = std::min(x - topLeft.x, bottomRight.x - x);
        float marginY = std::min(y - topLeft.y, bottomRight.y - y);
        float best = std::min(marginX, marginY);
        if (isLShape()) {
            float midX = (topLeft.x + bottomRight.x) * 0.5f;
            float midY = (topLeft.y + bottomRight.y) * 0.5f;
            bool cutLeft = (shape == 9 || shape == 11);
            bool cutTop  = (shape == 9 || shape == 10);
            float dx = cutLeft ? std::max(0.0f, midX - x) : std::max(0.0f, x - midX);
            float dy = cutTop  ? std::max(0.0f, midY - y) : std::max(0.0f, y - midY);
            // Distance to the quadrant corner/edges
            float distCut = 1e6f;
            if (dx > 0.0f && dy == 0.0f) distCut = cutTop ? (y - midY) : (midY - y);
            else if (dy > 0.0f && dx == 0.0f) distCut = cutLeft ? (x - midX) : (midX - x);
            else if (dx == 0.0f && dy == 0.0f) {
                float ox = cutLeft ? (x - midX) : (midX - x);
                float oy = cutTop  ? (y - midY) : (midY - y);
                distCut = std::sqrt(ox * ox + oy * oy);
            } else {
                distCut = 0.0f;
            }
            best = std::min(best, distCut);
        }
        return best;
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
        if (isLShape() && lRoomCutoutOverflow(x, y, margin) > 0.0f) {
            return false;
        }
        return true;
    }

    // Physical passability only (walls, rocks, pits, key blocks).
    // Floor spikes and shop pedestals have GRIDCOLL_NONE in Isaac and do NOT cause wall-sliding!
    bool cellPhysicallyPassable(int idx, bool canFly) const {
        if (idx < 0 || idx >= cellCount) return beast;
        uint8_t f = cells[idx];
        uint8_t solidMask = canFly ? kSolidFly : kSolidGround;
        return (f & solidMask) == 0;
    }

    bool cellAutoAvoid(int idx) const {
        return idx >= 0 && idx < cellCount && (cells[idx] & kAutoAvoid) != 0;
    }

    bool footprintSafe(float x, float y, float radius, bool canFly) const {
        float r = std::max(2.0f, radius - 1.0f);
        if (!beast && !isLShape() && pitch.x == 40.0f && pitch.y == 40.0f) {
            if (x - r < topLeft.x || x + r > bottomRight.x ||
                y - r < topLeft.y || y + r > bottomRight.y) {
                return false;
            }
            if (!hasSolidCells) return true;
            float ox = x - origin.x;
            float oy = y - origin.y;
            if (ox >= r && oy >= r) {
                int c0 = static_cast<int>((ox - r) * 0.025f + 0.5f);
                int c1 = static_cast<int>((ox + r) * 0.025f + 0.5f);
                int r0 = static_cast<int>((oy - r) * 0.025f + 0.5f);
                int r1 = static_cast<int>((oy + r) * 0.025f + 0.5f);
                if (c0 >= 0 && c1 < width && r0 >= 0 && r1 < height) {
                    if (c0 == c1 && r0 == r1) {
                        return cellPhysicallyPassable(c0 + r0 * width, canFly);
                    }
                    if (c1 - c0 <= 1 && r1 - r0 <= 1) {
                        if (cellPhysicallyPassable(c0 + r0 * width, canFly) &&
                            cellPhysicallyPassable(c1 + r0 * width, canFly) &&
                            cellPhysicallyPassable(c0 + r1 * width, canFly) &&
                            cellPhysicallyPassable(c1 + r1 * width, canFly)) {
                            return true;
                        }
                    }
                }
            }
        }
        if (!inBoundsPoint(x, y, 0.0f)) return false;
        int centerIdx = indexAt(x, y);
        if (!cellPhysicallyPassable(centerIdx, canFly)) return false;
        static constexpr float kDiag = 0.70710678f;
        static constexpr float kDirX[8] = {-1, 1, 0, 0, -kDiag, kDiag, -kDiag, kDiag};
        static constexpr float kDirY[8] = {0, 0, -1, 1, -kDiag, -kDiag, kDiag, kDiag};
        for (int i = 0; i < 8; ++i) {
            float px = x + kDirX[i] * r;
            float py = y + kDirY[i] * r;
            if (!inBoundsPoint(px, py, 0.0f)) return false;
            int idx = indexAt(px, py);
            if (!cellPhysicallyPassable(idx, canFly)) return false;
        }
        return true;
    }

    // Line-of-sight check for tears/projectiles against grid obstacles (mode 3: solid non-pit).
    bool lineClearBullet(Vec2 a, Vec2 b) const {
        Vec2 d = b - a;
        float len = d.length();
        if (len < 1.0f) return true;
        int n = std::min(32, std::max(1, static_cast<int>(len / 16.0f)));
        for (int i = 1; i < n; ++i) {
            float t = static_cast<float>(i) / static_cast<float>(n);
            Vec2 p = a + d * t;
            int idx = indexAt(p.x, p.y);
            if (idx < 0) return false;
            uint8_t cf = cells[idx];
            if ((cf & kSolidFly) || ((cf & kSolidGround) && !(cf & kPit))) return false;
        }
        return true;
    }
};

struct PlayerState {
    uintptr_t ptr = 0;
    Vec2 pos;
    Vec2 vel; // Note: already in px per 60Hz player update (Entity_Player updates twice per 30Hz frame)
    float size = 10.0f;
    float moveSpeed = 1.0f;
    bool canFly = false;
    bool slippery = false;
    int controllerIndex = 0;
    uint32_t initSeed = 0;
    float tearDamage = 3.5f;
};

struct ThreatScene {
    bool valid = false;
    bool paused = false;
    bool passthrough = false; // true when native must hand off directly to raw keys (dead/cooldown/cutscene/entry)
    bool deathmatch = false;
    bool hasTwin = false;
    uint32_t tick60 = 0;
    float entityPhase = 0.0f; // +0.5f updates on offline odd tick before non-player entities interpolate
    int frameCount30 = 0;
    int steps60 = 27;
    int queueDelay30 = 0;
    RoomGrid grid;
    PlayerState player;
    PlayerState twin; // Shared-controller twin (e.g. Esau when bound to Jacob)
    std::vector<BulletTrack> bullets;
    std::vector<DiscHazard> discs;
    std::vector<LaserHazard> lasers;

    void clear() {
        valid = false;
        paused = false;
        passthrough = false;
        deathmatch = false;
        hasTwin = false;
        entityPhase = 0.0f;
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

inline uintptr_t sanitizePtr32(uint32_t raw) {
    return (raw >= 0x10000u) ? static_cast<uintptr_t>(raw) : 0;
}

inline bool readEntityLifeState(const MemReader& mem, uintptr_t entAddr,
                                uint64_t& flagsOut, uint8_t& existsOut,
                                uint8_t& deadOut, uint8_t& interpOut) {
    static_assert(Offsets::Entity::kExists == Offsets::Entity::kFlags + 10u &&
                  Offsets::Entity::kDead == Offsets::Entity::kFlags + 11u &&
                  Offsets::Entity::kInterpolated == Offsets::Entity::kFlags + 13u,
                  "Entity life block layout");
    uint8_t lifeBuf[14]{};
    if (mem.readBytes(entAddr + Offsets::Entity::kFlags, lifeBuf, sizeof(lifeBuf))) {
        std::memcpy(&flagsOut, lifeBuf, sizeof(flagsOut));
        existsOut = lifeBuf[10];
        deadOut = lifeBuf[11];
        interpOut = lifeBuf[13];
        return true;
    }
    if (!mem.read(entAddr + Offsets::Entity::kExists, existsOut)) return false;
    if (!existsOut) { deadOut = 0; interpOut = 0; flagsOut = 0; return true; }
    mem.read(entAddr + Offsets::Entity::kDead, deadOut);
    mem.read(entAddr + Offsets::Entity::kInterpolated, interpOut);
    mem.read(entAddr + Offsets::Entity::kFlags, flagsOut);
    return true;
}

inline bool readSpriteState(const MemReader& mem, uintptr_t spriteAddr,
                            char* animBuf, size_t animCap,
                            float& frameOut, bool& playingOut, bool& flipXOut) {
    animBuf[0] = '\0';
    frameOut = 0.0f;
    playingOut = false;
    flipXOut = false;
    if (!spriteAddr) return false;
    static_assert(Offsets::Sprite::kFrame == Offsets::Sprite::kAnimData + 12u &&
                  Offsets::Sprite::kPlaying == Offsets::Sprite::kAnimData + 16u,
                  "Sprite header layout");
    uint8_t sprHdr[17]{};
    if (!mem.readBytes(spriteAddr + Offsets::Sprite::kAnimData, sprHdr, sizeof(sprHdr))) {
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
    uint32_t rawAnimPtr = 0;
    std::memcpy(&rawAnimPtr, sprHdr, 4);
    uintptr_t animData = sanitizePtr32(rawAnimPtr);
    if (!animData) return false;
    if (!mem.readMsvcString(animData, animBuf, animCap)) return false;
    std::memcpy(&frameOut, sprHdr + 12, sizeof(float));
    playingOut = (sprHdr[16] != 0);
    uint8_t fx = 0;
    mem.read(spriteAddr + Offsets::Sprite::kFlipX, fx);
    flipXOut = (fx != 0);
    return true;
}

inline bool readLogicPosFast(const MemReader& mem, uintptr_t entAddr, bool wasInterp, Vec2& outPos) {
    static_assert(Offsets::Entity::kInterpPrevPos == Offsets::Entity::kPos + 8u, "Entity pos pair layout");
    Vec2 pair[2]{};
    if (mem.readBytes(entAddr + Offsets::Entity::kPos, pair, sizeof(pair))) {
        if (wasInterp && std::isfinite(pair[1].x) && std::isfinite(pair[1].y)) {
            outPos = pair[1];
            return true;
        }
        if (std::isfinite(pair[0].x) && std::isfinite(pair[0].y)) {
            outPos = pair[0];
            return true;
        }
        return false;
    }
    if (wasInterp) {
        Vec2 prev{};
        if (mem.read(entAddr + Offsets::Entity::kInterpPrevPos, prev) &&
            std::isfinite(prev.x) && std::isfinite(prev.y)) {
            outPos = prev;
            return true;
        }
    }
    return mem.read(entAddr + Offsets::Entity::kPos, outPos) &&
           std::isfinite(outPos.x) && std::isfinite(outPos.y);
}

// Read un-interpolated 30Hz logic position of a non-player entity.
// In Online Co-op (0x954cd0.c:213), NetManager polls input before clearing kInterpolated,
// so kPos holds kInterpPrevPos + 0.5*vel while kInterpPrevPos holds the true 30Hz logic position.
inline bool readLogicPos(const MemReader& mem, uintptr_t entAddr, Vec2& outPos, bool& wasInterp) {
    uint8_t interp = 0;
    mem.read(entAddr + Offsets::Entity::kInterpolated, interp);
    wasInterp = (interp != 0);
    return readLogicPosFast(mem, entAddr, wasInterp, outPos);
}

inline bool unsupportedPlayerType(int playerType) {
    switch (playerType) {
        case 16: // PLAYER_THEFORGOTTEN
        case 17: // PLAYER_THESOUL
        case 29: // PLAYER_LAZARUS_B
        case 35: // PLAYER_THEFORGOTTEN_B
        case 37: // PLAYER_JACOB_B
        case 38: // PLAYER_LAZARUS2_B
        case 39: // PLAYER_JACOB2_B (Tainted Jacob ghost form)
        case 40: // PLAYER_THESOUL_B
            return true;
        default:
            return false;
    }
}

inline bool isOurSidePlayer(const MemReader& mem, uintptr_t playerAddr,
                            uint32_t boundSeed, int myCtrlIdx) {
    if (!playerAddr) return false;
    uint32_t seed = 0;
    int ctrl = -999;
    mem.read(playerAddr + Offsets::Entity::kInitSeed, seed);
    mem.read(playerAddr + Offsets::Player::kControllerIndex, ctrl);
    return (seed == boundSeed) || (ctrl == myCtrlIdx);
}

inline bool isActiveEnemyRaw(int type, int variant, uint8_t dead, uint64_t flags) {
    if (dead) return false;
    if (flags & (IsaacEnums::kEntFlagFriendly | IsaacEnums::kEntFlagBossDeath | IsaacEnums::kEntFlagNoQuery)) {
        return false;
    }
    if (type < 10 || type > 999) return false;
    if (type == IsaacEnums::kEntShopkeeper || type == IsaacEnums::kEntFireplace ||
        type == IsaacEnums::kEntEmbryo || type == IsaacEnums::kEntMovingBox ||
        type == IsaacEnums::kEntGenericPrp || type == IsaacEnums::kEntMinecart) {
        return false;
    }
    if (type == IsaacEnums::kEntGideon && variant == 10) return false;
    return true;
}

struct OwnedMemo {
    std::array<uintptr_t, 16> unownedRoots{};
    int count = 0;

    bool hasUnowned(uintptr_t addr) const {
        for (int i = 0; i < count; ++i) {
            if (unownedRoots[i] == addr) return true;
        }
        return false;
    }

    void addUnowned(uintptr_t addr) {
        if (!addr || count >= static_cast<int>(unownedRoots.size()) || hasUnowned(addr)) return;
        unownedRoots[count++] = addr;
    }
};

// Exact parity with core.lua:240-258 playerOwned(entity), supporting familiars (Type 3),
// SpawnerType 1/3, Deathmatch Familiar::Player (+0x410), shared-controller twins (Jacob & Esau),
// and walking BOTH Parent and SpawnerEntity without falsely trusting FLAG_CHARMED.
inline bool isPlayerOwnedFast(const MemReader& mem, uintptr_t entAddr,
                              int eType, int eSpawnerType, uint64_t eFlags,
                              bool deathmatch, uint32_t boundSeed, int myCtrlIdx,
                              OwnedMemo* memo = nullptr) {
    if (!entAddr) return false;
    if (eFlags & IsaacEnums::kEntFlagFriendly) return true;
    if (!deathmatch && (eType == IsaacEnums::kEntPlayer || eType == IsaacEnums::kEntFamiliar ||
                        eSpawnerType == IsaacEnums::kEntPlayer || eSpawnerType == IsaacEnums::kEntFamiliar)) {
        return true;
    }

    if (deathmatch && eType == IsaacEnums::kEntFamiliar) {
        uintptr_t owner = mem.readPtr32(entAddr + Offsets::Familiar::kPlayer);
        if (isOurSidePlayer(mem, owner, boundSeed, myCtrlIdx)) return true;
    }

    static_assert(Offsets::Entity::kSpawnerEntity == Offsets::Entity::kParent + 12u, "Entity ptr link layout");
    uint32_t rootLinks[4]{};
    uintptr_t p0 = 0, p1 = 0;
    if (mem.readBytes(entAddr + Offsets::Entity::kParent, rootLinks, sizeof(rootLinks))) {
        p0 = sanitizePtr32(rootLinks[0]);
        p1 = sanitizePtr32(rootLinks[3]);
    } else {
        p0 = mem.readPtr32(entAddr + Offsets::Entity::kParent);
        p1 = mem.readPtr32(entAddr + Offsets::Entity::kSpawnerEntity);
    }
    if (!p0 && !p1) return false;
    if (memo && (!p0 || memo->hasUnowned(p0)) && (!p1 || memo->hasUnowned(p1))) {
        return false;
    }

    std::array<uintptr_t, 12> queue{};
    int head = 0, tail = 0;
    auto pushUnique = [&](uintptr_t p) {
        if (!p || tail >= static_cast<int>(queue.size())) return;
        if (memo && memo->hasUnowned(p)) return;
        for (int i = 0; i < tail; ++i) {
            if (queue[i] == p) return;
        }
        queue[tail++] = p;
    };
    pushUnique(p0);
    pushUnique(p1);

    static_assert(Offsets::Entity::kVariant == Offsets::Entity::kType + 4u &&
                  Offsets::Entity::kSubType == Offsets::Entity::kType + 8u &&
                  Offsets::Entity::kSpawnerType == Offsets::Entity::kType + 12u,
                  "Entity header block layout");
    while (head < tail) {
        uintptr_t cur = queue[head++];
        int32_t hdr[4]{};
        if (!mem.readBytes(cur + Offsets::Entity::kType, hdr, sizeof(hdr))) {
            if (!mem.read(cur + Offsets::Entity::kType, hdr[0])) continue;
            mem.read(cur + Offsets::Entity::kSpawnerType, hdr[3]);
        }
        int t = hdr[0], spawnerType = hdr[3];
        uint64_t flags = 0;
        mem.read(cur + Offsets::Entity::kFlags, flags);

        if (flags & IsaacEnums::kEntFlagFriendly) return true;

        if (deathmatch) {
            if (t == IsaacEnums::kEntPlayer) {
                if (isOurSidePlayer(mem, cur, boundSeed, myCtrlIdx)) return true;
            } else if (t == IsaacEnums::kEntFamiliar) {
                uintptr_t owner = mem.readPtr32(cur + Offsets::Familiar::kPlayer);
                if (isOurSidePlayer(mem, owner, boundSeed, myCtrlIdx)) return true;
            }
        } else {
            if (t == IsaacEnums::kEntPlayer || t == IsaacEnums::kEntFamiliar ||
                spawnerType == IsaacEnums::kEntPlayer || spawnerType == IsaacEnums::kEntFamiliar) {
                return true;
            }
        }

        uint32_t curLinks[4]{};
        if (mem.readBytes(cur + Offsets::Entity::kParent, curLinks, sizeof(curLinks))) {
            pushUnique(sanitizePtr32(curLinks[0]));
            pushUnique(sanitizePtr32(curLinks[3]));
        } else {
            pushUnique(mem.readPtr32(cur + Offsets::Entity::kParent));
            pushUnique(mem.readPtr32(cur + Offsets::Entity::kSpawnerEntity));
        }
    }

    if (memo && tail < static_cast<int>(queue.size())) {
        if (p0) memo->addUnowned(p0);
        if (p1) memo->addUnowned(p1);
    }
    return false;
}

inline bool isPlayerOwned(const MemReader& mem, uintptr_t entAddr,
                          bool deathmatch, uint32_t boundSeed, int myCtrlIdx) {
    if (!entAddr) return false;
    int32_t hdr[4]{};
    if (!mem.readBytes(entAddr + Offsets::Entity::kType, hdr, sizeof(hdr))) {
        if (!mem.read(entAddr + Offsets::Entity::kType, hdr[0])) return false;
        mem.read(entAddr + Offsets::Entity::kSpawnerType, hdr[3]);
    }
    uint64_t flags = 0;
    mem.read(entAddr + Offsets::Entity::kFlags, flags);
    return isPlayerOwnedFast(mem, entAddr, hdr[0], hdr[3], flags, deathmatch, boundSeed, myCtrlIdx);
}

inline bool isHarmlessVisualEffect(int variant) {
    switch (variant) {
        case 1:   // BOMB_EXPLOSION (lingering smoke; live bombs carry timed envelope)
        case 2:   // BLOOD_EXPLOSION
        case 4:   // ROCK_PARTICLE
        case 5:   // BLOOD_PARTICLE
        case 7:   // BLOOD_SPLAT
        case 12:  // BULLET_POOF
        case 13:  // TEAR_POOF_A
        case 14:  // TEAR_POOF_B
        case 15:  // POOF01
        case 16:  // POOF02
        case 17:  // POOF04
        case 25:  // CREEP_WHITE (slow only, 0 damage)
        case 26:  // CREEP_BLACK (slow only, 0 damage)
        case 56:  // CREEP_BROWN (slippery only, 0 damage)
        case 70:  // BLOOD_DROP
        case 71:  // BRIMSTONE_SWIRL (player visual)
        case 94:  // CREEP_SLIPPERY_BROWN (0 damage)
        case 145: // ROCK_POOF
        case 155: // CREEP_SLIPPERY_BROWN_GROWING (0 damage)
        case 200: // BULLET_POOF_STATIC
            return true;
        default:
            return false;
    }
}

inline bool isEnemyGroundCreep(int variant) {
    return variant == 22 || variant == 23 || variant == 24 || variant == 169 || variant == 195;
}

inline bool isPlayerCreepVariant(int variant) {
    switch (variant) {
        case 32: // PLAYER_CREEP_LEMON_MISHAP
        case 37: // PLAYER_CREEP_HOLYWATER
        case 44: // PLAYER_CREEP_WHITE
        case 45: // PLAYER_CREEP_BLACK
        case 46: // PLAYER_CREEP_RED
        case 53: // PLAYER_CREEP_GREEN
        case 54: // PLAYER_CREEP_HOLYWATER_TRAIL
        case 78: // PLAYER_CREEP_LEMON_PARTY
        case 90: // PLAYER_CREEP_PUDDLE_MILK
        case 92: // PLAYER_CREEP_BLACKPOWDER
        case 204:// PLAYER_CREEP_YELLOW
            return true;
        default:
            return false;
    }
}

// Base radius table matching core.lua:296-313 areaEffects (returns 0 if not in table).
inline float areaEffectBaseRadius(int variant, bool& warnOut) {
    warnOut = false;
    switch (variant) {
        case 19:  return 35.0f;  // CRACK_THE_SKY
        case 28:  return 24.0f;  // MONSTROS_TOOTH
        case 29:  return 65.0f;  // MOM_FOOT_STOMP
        case 30:  return 65.0f;  // TARGET
        case 31:  return 100.0f; // ROCKET
        case 38:  return 45.0f;  // MOMS_HAND
        case 51:
        case 52:  return 30.0f;  // HOT_BOMB_FIRE / RED_CANDLE_FLAME
        case 55:  return 20.0f;  // SPIKE
        case 61:
        case 67:
        case 73:  return 30.0f;  // SHOCKWAVE / DIRECTIONAL / RANDOM
        case 72:  return 35.0f;  // CRACKWAVE
        case 96:
        case 101: return 35.0f;  // HUSH_LASER / HUSH_LASER_UP
        case 110: return 45.0f;  // ENEMY_BRIMSTONE_SWIRL
        case 113: return 40.0f;  // BRIMSTONE_BALL
        case 115: return 65.0f;  // BROKEN_SHOVEL_SHADOW
        case 118: return 80.0f;  // SMALL_ROCKET
        case 125: return 45.0f;  // BIG_HORN_HAND
        case 146: warnOut = true; return 35.0f; // DIRT_PILE
        case 147:
        case 148: return 35.0f;  // FIRE_JET / FIRE_WAVE
        case 150: return 55.0f;  // BIG_CRACKWAVE
        case 182: return 50.0f;  // BIG_KNIFE
        case 183: return 40.0f;  // MOTHER_SHOCKWAVE
        case 187: return 50.0f;  // EXPLOSION_WAVE
        default:  return 0.0f;
    }
}

inline bool isExploderNpc(int type, int variant) {
    switch (type) {
        case IsaacEnums::kEntBoomFly:    return variant == 0 || variant == 2 || variant == 6;
        case IsaacEnums::kEntMulligan:   return variant == 2;
        case IsaacEnums::kEntLeech:      return variant == 1 || variant == 2;
        case IsaacEnums::kEntBlackMaw:
        case IsaacEnums::kEntTickingSpd:
        case IsaacEnums::kEntPoisonMind:
        case IsaacEnums::kEntBlackBony:
        case IsaacEnums::kEntFlyBomb:    return true;
        default:                         return false;
    }
}

inline bool isChaserExploder(int type, int variant) {
    if (type == IsaacEnums::kEntMulligan && variant == 2) return true;
    if (type == IsaacEnums::kEntLeech && (variant == 1 || variant == 2)) return true;
    if (type == IsaacEnums::kEntTickingSpd) return true;
    return false;
}

inline void addDirectedLaser(std::vector<LaserHazard>& out, Vec2 origin, Vec2 vel,
                             float angleDeg, float length, float halfWidth,
                             float activeFrom, bool warn) {
    if (out.size() >= 96) return;
    LaserHazard lh{};
    lh.origin = origin;
    lh.vel = vel;
    lh.pts[0] = {0.0f, 0.0f};
    constexpr float kDegToRad = 0.017453292519943295f;
    float r = angleDeg * kDegToRad;
    lh.pts[1] = {std::cos(r) * length, std::sin(r) * length};
    lh.numPts = 2;
    lh.reach = length;
    lh.width = halfWidth;
    lh.activeFrom = std::max(0.0f, activeFrom);
    lh.timeoutT = 1e6f;
    lh.warning = warn ? 1 : 0;
    out.push_back(lh);
}

inline void simulateBulletCommon(Vec2 pos, Vec2 vel, float size, float timeScale,
                                 float prevAge, float age, int spawnerType, int gridColl,
                                 float height, float fallSpeed, float fallAccel,
                                 float homing, float curving, float accel,
                                 uint64_t flags, int32_t wiggleOff,
                                 uint64_t changeFlags, float changeVel, int32_t changeTimeout,
                                 Vec2 targetPos, const ThreatScene& scene,
                                 float horizonUpdates, int steps60,
                                 BulletTrack& track, std::vector<DiscHazard>& discs) {
    if (flags & IsaacEnums::kProjCantHitPlayer) return;

    float playerSpeed30 = std::max(scene.player.vel.length(), 4.33f * scene.player.moveSpeed) * 2.0f;
    float estMaxSpeed = std::max(vel.length(), std::abs(changeVel)) + 6.0f;
    float reachLimit = playerSpeed30 * horizonUpdates + scene.player.size + size + 120.0f + estMaxSpeed * horizonUpdates;
    if ((pos - scene.player.pos).length() > reachLimit && (flags & IsaacEnums::kProjContinuum) == 0) {
        return;
    }

    int clampedSteps = std::min(steps60, BulletTrack::kMaxPts - 1);
    track.radius = std::max(1.0f, size) + 3.0f;
    bool anyHeight = (flags & IsaacEnums::kProjAnyHeightHit) != 0;
    constexpr float kTwoPi = 6.28318530718f;
    float dtStep = 0.5f * timeScale;
    bool continuum = (flags & IsaacEnums::kProjContinuum) != 0;
    bool noWallCollide = (flags & IsaacEnums::kProjNoWallCollide) != 0;
    bool ignoreFloorHeight = (scene.grid.type == 16 && !scene.grid.beast);
    bool enteredRoom = scene.grid.inBoundsPoint(pos.x, pos.y, 0.0f);

    // Helper advancing one 0.5-update step in-place.
    float simAge = age;
    float prevSimAge = prevAge;
    auto advanceHalfUpdate = [&](Vec2& curPos, float& curH, float& curFs) -> bool {
        float dt = dtStep;
        float nextSimAge = simAge + dt;

        // ChangeTimeout (0x65a630 / 0x6ac760): triggers when int(nextAge / timeout) > int(prevAge / timeout)
        // and swaps ProjectileFlags <-> ChangeFlags while updating curving/velocity.
        if (changeTimeout > 0 && ((flags & (IsaacEnums::kProjChangeFlags | IsaacEnums::kProjChangeVelocity)) != 0)) {
            int prevBucket = static_cast<int>(std::max(0.0f, simAge) / static_cast<float>(changeTimeout));
            int nextBucket = static_cast<int>(std::max(0.0f, nextSimAge) / static_cast<float>(changeTimeout));
            if (nextBucket > prevBucket) {
                if (flags & IsaacEnums::kProjChangeVelocity) {
                    if (changeVel > 0.0f && (changeFlags & (IsaacEnums::kProjCurveLeft | IsaacEnums::kProjCurveRight)) == 0) {
                        vel = vel.resized(changeVel);
                    } else {
                        curving = changeVel;
                    }
                }
                if (flags & IsaacEnums::kProjChangeFlags) {
                    std::swap(flags, changeFlags);
                    continuum = (flags & IsaacEnums::kProjContinuum) != 0;
                    noWallCollide = (flags & IsaacEnums::kProjNoWallCollide) != 0;
                    anyHeight = (flags & IsaacEnums::kProjAnyHeightHit) != 0;
                }
            }
        }

        // Homing: SMART_PERFECT (0x6583e5) vs SMART (0x6585c0)
        if (flags & IsaacEnums::kProjSmartPerfect) {
            float keepSpd = std::max(0.001f, vel.length());
            vel = (vel + (targetPos - curPos) * (0.1f * dt)).resized(keepSpd);
        } else if ((flags & IsaacEnums::kProjSmart) && homing != 0.0f) {
            Vec2 toTarget = targetPos - curPos;
            float dist = toTarget.length();
            if (dist > 1.0f && dist < 100.0f) {
                vel += toTarget.normalized() * (1.4f * homing * dt);
                vel *= std::pow(0.92f, std::min(4.0f, std::abs(homing)) * dt);
            }
        }

        // Curving (CURVE_LEFT / CURVE_RIGHT, 0x658ec3)
        if ((flags & (IsaacEnums::kProjCurveLeft | IsaacEnums::kProjCurveRight)) && curving != 0.0f) {
            float spd = vel.length();
            if (spd > 1e-4f) {
                Vec2 perp = (flags & IsaacEnums::kProjCurveLeft)
                    ? Vec2{vel.y, -vel.x}
                    : Vec2{-vel.y, vel.x};
                vel = (vel + perp * (spd * curving * dt)).resized(spd);
            }
        }

        // Acceleration / Deceleration / AccelerateEx (0x659a4e..0x659c10)
        if ((flags & IsaacEnums::kProjAccelerate) && accel > 0.01f) {
            vel *= std::pow(accel, dt);
        }
        if ((flags & IsaacEnums::kProjDecelerate) && accel > 0.01f) {
            vel *= std::pow(1.0f / accel, dt);
        }
        if ((flags & IsaacEnums::kProjAccelerateEx) && accel > 0.01f) {
            float blendAge = std::min(1.0f, nextSimAge / 20.0f);
            float factor = 1.0f + (accel - 1.0f) * blendAge;
            vel *= std::pow(std::max(0.05f, factor), dt);
        }

        Vec2 nextPos = curPos + vel * dt;

        // Wave offsets: SINE_VELOCITY uses sin (0x65954d -> 0x417160), WIGGLE / MEGA_WIGGLE use cos (0x65961e -> 0x417150)
        if (flags & IsaacEnums::kProjSineVelocity) {
            nextPos += vel * (std::sin(nextSimAge * kTwoPi / 60.0f) * dt);
        }
        if (flags & (IsaacEnums::kProjWiggle | IsaacEnums::kProjMegaWiggle)) {
            float spd = vel.length();
            if (spd > 1e-4f) {
                Vec2 perp = Vec2{vel.y / spd, -vel.x / spd};
                float phaseMul = (spawnerType == IsaacEnums::kEntMother) ? 2.0f : 1.0f;
                float phase = (static_cast<float>(wiggleOff) + nextSimAge) * phaseMul * kTwoPi / 60.0f;
                float amp = (flags & IsaacEnums::kProjMegaWiggle)
                    ? (std::min(4.0f, std::max(0.0f, (static_cast<float>(wiggleOff) + nextSimAge) * 0.04f)) + 3.0f)
                    : 3.0f;
                nextPos += perp * (std::cos(phase) * amp * dt);
            }
        }

        if ((flags & IsaacEnums::kProjTurnHorizontal) && std::abs(nextPos.y - targetPos.y) < 12.0f) {
            float spd = std::max(vel.length() * 1.3f, 8.0f);
            vel = Vec2{(targetPos.x >= nextPos.x) ? spd : -spd, 0.0f};
        }

        // Gravity / Height (0x65a26c & BOUNCE_FLOOR 0x65a6e8..0x65a736)
        float nextFs = std::pow(0.9f, dt) * curFs + (0.1f + fallAccel) * dt;
        float nextH = curH + nextFs * dt;

        if (!ignoreFloorHeight) {
            int gidx = scene.grid.indexAt(nextPos.x, nextPos.y);
            bool overSolid = (gidx >= 0) && ((scene.grid.cells[gidx] & RoomGrid::kSolidGround) != 0) &&
                             ((scene.grid.cells[gidx] & RoomGrid::kPit) == 0);
            float bounceH = ((flags & IsaacEnums::kProjBounceFloor) && overSolid) ? -50.0f : -5.0f;
            if (nextH > bounceH) {
                if ((flags & IsaacEnums::kProjBounceFloor) && nextFs > 2.0f) {
                    nextH = bounceH;
                    nextFs = nextFs * -2.0f;
                } else if (nextH > -5.0f) {
                    curPos = nextPos; curH = nextH; curFs = nextFs;
                    return false; // landed
                }
            }
        }
        if (scene.grid.beast && vel.y > 0.0f && nextPos.y > scene.grid.beastGroundY) {
            curPos = nextPos; curH = nextH; curFs = nextFs;
            return false;
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
            bool nowInRoom = scene.grid.inBoundsPoint(nextPos.x, nextPos.y, 0.0f);
            if (nowInRoom) enteredRoom = true;
            int gidx = scene.grid.indexAt(nextPos.x, nextPos.y);
            bool hitOuterWall = enteredRoom && !nowInRoom;
            bool hitObstacle = false;
            if (enteredRoom && gridColl != 0 && gidx >= 0) {
                uint8_t cf = scene.grid.cells[gidx];
                if ((cf & RoomGrid::kSolidFly) ||
                    ((cf & RoomGrid::kSolidGround) && !(cf & RoomGrid::kPit) && nextH > -45.0f)) {
                    hitObstacle = true;
                }
            }
            if (hitOuterWall || hitObstacle) {
                if (flags & IsaacEnums::kProjBounce) {
                    bool hitX = !scene.grid.inBoundsPoint(nextPos.x, curPos.y, 0.0f) ||
                                (gridColl != 0 && gidx >= 0 && gidx != scene.grid.indexAt(curPos.x, nextPos.y));
                    bool hitY = !scene.grid.inBoundsPoint(curPos.x, nextPos.y, 0.0f) ||
                                (gridColl != 0 && gidx >= 0 && gidx != scene.grid.indexAt(nextPos.x, curPos.y));
                    if (hitX) vel.x = -vel.x * 0.9f;
                    if (hitY) vel.y = -vel.y * 0.9f;
                    if (!hitX && !hitY) vel = vel * -0.9f;
                    nextPos = curPos + vel * dt;
                } else {
                    curPos = nextPos; curH = nextH; curFs = nextFs;
                    return false;
                }
            }
        }

        prevSimAge = simAge;
        simAge = nextSimAge;
        curPos = nextPos;
        curFs = nextFs;
        curH = nextH;
        return true;
    };

    (void)prevSimAge;

    // If on an offline odd 60Hz tick before non-player interpolation, align projectile t=0 to player's +0.5 phase.
    if (scene.entityPhase > 0.0f) {
        if (!advanceHalfUpdate(pos, height, fallSpeed)) {
            if ((flags & IsaacEnums::kProjExplode) && discs.size() < 384) {
                discs.push_back(DiscHazard{pos, {0.0f, 0.0f}, 85.0f, 0.0f, 2.0f, 0});
            }
            return;
        }
    }

    // Calibrated height band [-60 .. +20] matching threat_field.lua:92 (covers hits recorded at Height = -49).
    bool activeAtZero = anyHeight || (height >= -60.0f && height <= 20.0f);
    track.pts[0] = pos;
    track.firstStep = activeAtZero ? 0 : 1;
    track.lastStep = activeAtZero ? 0 : -1;
    track.warning = 0;
    track.minX = track.maxX = pos.x;
    track.minY = track.maxY = pos.y;

    bool landed = false;
    float prevH = height;
    for (int k = 1; k <= clampedSteps; ++k) {
        if (!advanceHalfUpdate(pos, height, fallSpeed)) {
            track.pts[k] = pos;
            track.minX = std::min(track.minX, pos.x); track.maxX = std::max(track.maxX, pos.x);
            track.minY = std::min(track.minY, pos.y); track.maxY = std::max(track.maxY, pos.y);
            bool heightActive = anyHeight || (std::max(prevH, height) >= -60.0f && std::min(prevH, height) <= 20.0f);
            if (heightActive) {
                if (track.lastStep < 0) track.firstStep = k;
                track.lastStep = k;
            }
            landed = true;
            break;
        }
        track.pts[k] = pos;
        track.minX = std::min(track.minX, pos.x); track.maxX = std::max(track.maxX, pos.x);
        track.minY = std::min(track.minY, pos.y); track.maxY = std::max(track.maxY, pos.y);
        bool heightActive = anyHeight || (std::max(prevH, height) >= -60.0f && std::min(prevH, height) <= 20.0f);
        if (heightActive) {
            if (track.lastStep < 0) track.firstStep = k;
            track.lastStep = k;
        }
        prevH = height;
    }

    if (landed && (flags & IsaacEnums::kProjExplode) && track.lastStep >= 0 && discs.size() < 384) {
        float tImpact = static_cast<float>(track.lastStep) * 0.5f;
        Vec2 impPos = track.pts[track.lastStep];
        discs.push_back(DiscHazard{impPos, {0.0f, 0.0f}, 85.0f,
                                   std::max(0.0f, tImpact - 0.5f), tImpact + 2.0f, 0});
    }
}

inline void simulateProjectilePreloaded(const MemReader& mem, uintptr_t entAddr, Vec2 ePos, Vec2 vel,
                                        float size, int spawnerType, int gridColl,
                                        const ThreatScene& scene, float horizonUpdates,
                                        int steps60, BulletTrack& track, std::vector<DiscHazard>& discs) {
    if (!std::isfinite(vel.x) || !std::isfinite(vel.y)) return;
    static_assert(Offsets::Entity::kPrevAgeFloat == Offsets::Entity::kTimeScale + 4u &&
                  Offsets::Entity::kAgeFloat == Offsets::Entity::kTimeScale + 8u,
                  "Entity age block");
    float ageBlock[3] = {1.0f, 0.0f, 0.0f};
    if (!mem.readBytes(entAddr + Offsets::Entity::kTimeScale, ageBlock, sizeof(ageBlock))) {
        mem.read(entAddr + Offsets::Entity::kTimeScale, ageBlock[0]);
        mem.read(entAddr + Offsets::Entity::kPrevAgeFloat, ageBlock[1]);
        mem.read(entAddr + Offsets::Entity::kAgeFloat, ageBlock[2]);
    }
    float timeScale = std::max(0.1f, std::min(2.5f, std::isfinite(ageBlock[0]) ? ageBlock[0] : 1.0f));
    float prevAge = ageBlock[1], age = ageBlock[2];

    static_assert(Offsets::Projectile::kFallingSpeed == Offsets::Projectile::kHeight + 4u &&
                  Offsets::Projectile::kFallingAccel == Offsets::Projectile::kHeight + 8u &&
                  Offsets::Projectile::kHomingStrength == Offsets::Projectile::kHeight + 20u &&
                  Offsets::Projectile::kCurvingStrength == Offsets::Projectile::kHeight + 24u &&
                  Offsets::Projectile::kAcceleration == Offsets::Projectile::kHeight + 28u &&
                  Offsets::Projectile::kFlags == Offsets::Projectile::kHeight + 40u &&
                  Offsets::Projectile::kWiggleOffset == Offsets::Projectile::kHeight + 56u &&
                  Offsets::Projectile::kChangeFlags == Offsets::Projectile::kHeight + 64u &&
                  Offsets::Projectile::kChangeVelocity == Offsets::Projectile::kHeight + 72u &&
                  Offsets::Projectile::kChangeTimeout == Offsets::Projectile::kHeight + 76u,
                  "Projectile block layout");
    float height = -23.0f, fallSpeed = 0.0f, fallAccel = 0.0f;
    float homing = 0.0f, curving = 0.0f, accel = 1.0f, changeVel = 0.0f;
    uint64_t flags = 0, changeFlags = 0;
    int32_t wiggleOff = 0, changeTimeout = 0;
    uint8_t pBuf[80]{};
    if (mem.readBytes(entAddr + Offsets::Projectile::kHeight, pBuf, sizeof(pBuf))) {
        std::memcpy(&height, pBuf + 0, 4);
        std::memcpy(&fallSpeed, pBuf + 4, 4);
        std::memcpy(&fallAccel, pBuf + 8, 4);
        std::memcpy(&homing, pBuf + 20, 4);
        std::memcpy(&curving, pBuf + 24, 4);
        std::memcpy(&accel, pBuf + 28, 4);
        std::memcpy(&flags, pBuf + 40, 8);
        std::memcpy(&wiggleOff, pBuf + 56, 4);
        std::memcpy(&changeFlags, pBuf + 64, 8);
        std::memcpy(&changeVel, pBuf + 72, 4);
        std::memcpy(&changeTimeout, pBuf + 76, 4);
    } else {
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
    }

    Vec2 targetPos = scene.player.pos;
    constexpr uint64_t kNeedTargetMask =
        IsaacEnums::kProjSmart | IsaacEnums::kProjSmartPerfect | IsaacEnums::kProjTurnHorizontal;
    if ((flags & kNeedTargetMask) != 0 || ((flags & IsaacEnums::kProjChangeFlags) != 0 && (changeFlags & kNeedTargetMask) != 0)) {
        uintptr_t targetPtr = mem.readPtr32(entAddr + Offsets::Entity::kTarget);
        if (targetPtr) {
            Vec2 tp{};
            bool dummy = false;
            if (readLogicPos(mem, targetPtr, tp, dummy)) targetPos = tp;
        }
    }

    simulateBulletCommon(ePos, vel, size, timeScale, prevAge, age, spawnerType, gridColl,
                         height, fallSpeed, fallAccel, homing, curving, accel,
                         flags, wiggleOff, changeFlags, changeVel, changeTimeout,
                         targetPos, scene, horizonUpdates, steps60, track, discs);
}

inline void simulateProjectile(const MemReader& mem, uintptr_t entAddr, Vec2 ePos,
                               const ThreatScene& scene, float horizonUpdates,
                               int steps60, BulletTrack& track, std::vector<DiscHazard>& discs) {
    Vec2 vel{};
    float size = 4.0f;
    int spawnerType = 0, gridColl = 3;
    mem.read(entAddr + Offsets::Entity::kSpawnerType, spawnerType);
    mem.read(entAddr + Offsets::Entity::kGridColl, gridColl);
    mem.read(entAddr + Offsets::Entity::kVel, vel);
    mem.read(entAddr + Offsets::Entity::kSize, size);
    simulateProjectilePreloaded(mem, entAddr, ePos, vel, size, spawnerType, gridColl,
                                scene, horizonUpdates, steps60, track, discs);
}

// Chubber boomerang grub (39.22.0, Parent=39.2.0, verified 0x52c2f0..0x52c50c):
// StateFrame = 0..42 (dies >42), frac = 1 - sf/21; outbound (frac >= 0 or !parent): vel = V1 * frac;
// return leg (frac < 0 && parent): pulls to Parent via max(0, d-20)/d * toParent / max(1, 43-sf) * (-frac).
inline void simulateChubberWorm(const MemReader& mem, uintptr_t entAddr, Vec2 ePos, Vec2 eVel, float eSize,
                                const ThreatScene& scene, int steps60, BulletTrack& track) {
    int32_t sfRaw = 0;
    Vec2 v1{};
    mem.read(entAddr + Offsets::NPC::kStateFrame, sfRaw);
    mem.read(entAddr + Offsets::NPC::kV1, v1);

    uint32_t links[4]{};
    uintptr_t parentAddr = 0;
    if (mem.readBytes(entAddr + Offsets::Entity::kParent, links, sizeof(links))) {
        uintptr_t p = sanitizePtr32(links[0]);
        parentAddr = p ? p : sanitizePtr32(links[3]);
    } else {
        parentAddr = mem.readPtr32(entAddr + Offsets::Entity::kParent);
        if (!parentAddr) parentAddr = mem.readPtr32(entAddr + Offsets::Entity::kSpawnerEntity);
    }

    bool hasParent = false;
    Vec2 parentPos{}, parentVel{};
    if (parentAddr) {
        uint64_t pFlags = 0;
        uint8_t pEx = 0, pDead = 0, pInterp = 0;
        if (readEntityLifeState(mem, parentAddr, pFlags, pEx, pDead, pInterp) &&
            pEx && !pDead && readLogicPosFast(mem, parentAddr, pInterp != 0, parentPos)) {
            hasParent = true;
            mem.read(parentAddr + Offsets::Entity::kVel, parentVel);
            if (!std::isfinite(parentVel.x) || !std::isfinite(parentVel.y)) parentVel = {0.0f, 0.0f};
        }
    }

    int sf = std::max(0, static_cast<int>(sfRaw));
    if (hasParent && sf == 0) {
        Vec2 fromP = ePos - parentPos;
        if (fromP.lengthSq() > 400.0f && (fromP.x * eVel.x + fromP.y * eVel.y) < 0.0f) {
            sf = 32;
        }
    }
    if (!std::isfinite(v1.x) || !std::isfinite(v1.y) || v1.lengthSq() < 1e-6f) {
        if (std::isfinite(eVel.x) && std::isfinite(eVel.y) && eVel.lengthSq() > 1e-4f) {
            float f0 = 1.0f - static_cast<float>(sf) / 21.0f;
            if ((!hasParent && std::abs(f0) > 0.04f) || (sf <= 20 && f0 > 0.04f)) {
                v1 = eVel * (1.0f / f0);
            } else {
                v1 = eVel;
            }
        } else {
            v1 = {0.0f, 0.0f};
        }
    }
    if (sf > 42) return;

    const int clampedSteps = std::min(steps60, BulletTrack::kMaxPts - 1);
    float simSf = static_cast<float>(sf);
    Vec2 curPos = ePos;
    Vec2 curParentPos = parentPos;

    auto evalVelAt = [&](int curSf, Vec2 p, Vec2 pp) -> Vec2 {
        float frac = 1.0f - static_cast<float>(curSf) / 21.0f;
        if (frac >= 0.0f || !hasParent) {
            return v1 * frac;
        }
        Vec2 toP = pp - p;
        float d = toP.length();
        if (d <= 20.0f || d <= 1e-4f) return {0.0f, 0.0f};
        Vec2 pull = toP * ((d - 20.0f) / d);
        int rem = std::max(1, 43 - curSf);
        return pull * ((-frac) / static_cast<float>(rem));
    };

    if (scene.entityPhase > 0.0f) {
        int curSf = static_cast<int>(std::floor(simSf + 1e-4f));
        if (curSf > 42) return;
        curPos += evalVelAt(curSf, curPos, curParentPos) * 0.5f;
        if (hasParent) curParentPos += parentVel * 0.5f;
        simSf += 0.5f;
    }

    track.radius = eSize + 3.0f;
    track.pts[0] = curPos;
    track.firstStep = 0;
    track.lastStep = 0;
    track.warning = 0;
    track.minX = track.maxX = curPos.x;
    track.minY = track.maxY = curPos.y;

    for (int k = 1; k <= clampedSteps; ++k) {
        int curSf = static_cast<int>(std::floor(simSf + 1e-4f));
        if (curSf > 42) break;
        curPos += evalVelAt(curSf, curPos, curParentPos) * 0.5f;
        if (hasParent) curParentPos += parentVel * 0.5f;
        simSf += 0.5f;
        track.pts[k] = curPos;
        track.minX = std::min(track.minX, curPos.x);
        track.maxX = std::max(track.maxX, curPos.x);
        track.minY = std::min(track.minY, curPos.y);
        track.maxY = std::max(track.maxY, curPos.y);
        track.lastStep = k;
    }
}

inline void appendNpcIntentWarnings(const MemReader& mem, uintptr_t entAddr,
                                    int type, int variant, float size, Vec2 pos, Vec2 vel,
                                    const ThreatScene& scene, float horizonUpdates,
                                    std::vector<DiscHazard>& discs,
                                    std::vector<LaserHazard>& lasers) {
    Vec2 sprOff{};
    mem.read(entAddr + Offsets::Entity::kSpriteOffset, sprOff);

    int state = 0, stateFrame = 0, i1 = 0;
    if (type == IsaacEnums::kEntUriel || type == IsaacEnums::kEntGabriel) {
        mem.read(entAddr + Offsets::NPC::kState, state);
        mem.read(entAddr + Offsets::NPC::kStateFrame, stateFrame);
        mem.read(entAddr + Offsets::NPC::kI1, i1);
    } else if (type == IsaacEnums::kEntFallen && variant == 1) {
        mem.read(entAddr + Offsets::NPC::kI1, i1);
    }

    char anim[64];
    float frame = 0.0f;
    bool playing = false, flipX = false;
    readSpriteState(mem, entAddr + Offsets::Entity::kSprite, anim, sizeof(anim), frame, playing, flipX);

    float roomDiag = (scene.grid.bottomRight - scene.grid.topLeft).length();
    if (roomDiag < 200.0f) roomDiag = 800.0f;

    // 1. Mom door arm ("ArmOpen" frame <= 12.5)
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
        discs.push_back(DiscHazard{pos, vel, size + 23.0f, 0.0f, horizonUpdates, 1});
    }

    // 7. Brimstone / Boss Laser Windups (exact parity with laser_hazards.lua + Sprite.FlipX Dogma fix)
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

    if (type == IsaacEnums::kEntVis && variant == 2 && strStartsWith(anim, "Attack03") && frame <= 30.0f) {
        const char* side = anim + 8;
        float ang = 0.0f;
        bool matched = true;
        if (std::strcmp(side, "Horiz") == 0) ang = flipX ? 180.0f : 0.0f;
        else if (std::strcmp(side, "Right") == 0) ang = 0.0f;
        else if (std::strcmp(side, "Left") == 0) ang = 180.0f;
        else if (std::strcmp(side, "Down") == 0) ang = 90.0f;
        else if (std::strcmp(side, "Up") == 0) ang = 270.0f;
        else matched = false;
        if (matched) {
            Vec2 dir = Vec2{1.0f, 0.0f}.rotatedDeg(ang);
            float reach = 260.0f;
            for (float s = 40.0f; s <= 260.0f; s += 40.0f) {
                if (!scene.grid.inBoundsPoint(pos.x + dir.x * s, pos.y + dir.y * s, 0.0f)) {
                    reach = s;
                    break;
                }
            }
            if (reach >= 40.0f) {
                addDirectedLaser(lasers, pos, {0.0f, 0.0f}, ang, reach, 16.0f, 0.0f, true);
            }
        }
    } else if ((type == IsaacEnums::kEntVis && variant != 2) || type == IsaacEnums::kEntGluttony) {
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
    } else if (type == IsaacEnums::kEntFallen && variant == 1 &&
               (std::strcmp(anim, "Attack2Alt") == 0 || std::strcmp(anim, "Attack2") == 0)) {
        const bool diag = (std::strcmp(anim, "Attack2") == 0 && i1 != 0);
        const float af = std::max(0.5f, 29.0f - frame);
        for (float base : {0.0f, 90.0f, 180.0f, 270.0f}) {
            addDirectedLaser(lasers, pos, vel, base + (diag ? 45.0f : 0.0f), roomDiag, 24.0f, af, false);
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
}

struct PlayerShotTear {
    Vec2 pos, vel;
    float size = 4.0f;
    float dmg = 3.5f;
    float height = -23.0f;
    float fallSpeed = 0.0f;
    float fallAccel = 0.0f;
    int gridColl = 3;
    uint64_t flagsLo = 0;
    uint64_t flagsHi = 0;

    bool aloftAt(int t) const {
        float h = height, fs = fallSpeed;
        for (int s = 1; s <= t; ++s) {
            fs = 0.9f * fs + (0.1f + fallAccel);
            h += fs;
            if (h > -5.0f) return false;
        }
        return true;
    }
};

struct PlayerShotBeam {
    Vec2 a, b;
    float size = 12.0f;
    float dmg = 3.5f;
    int timeout = 0;
};

struct ExploderSnap {
    Vec2 pos, vel;
    float size = 13.0f;
    float hp = 10.0f;
    int type = 0;
    int variant = 0;
    bool dead = false;
    float animFrame = 0.0f;
    bool animExplode = false;
};

inline float pointSegDist(Vec2 p, Vec2 a, Vec2 b) {
    Vec2 ab = b - a, ap = p - a;
    float lenSq = ab.lengthSq();
    float u = (lenSq > 1e-6f) ? std::max(0.0f, std::min(1.0f, ap.dot(ab) / lenSq)) : 0.0f;
    return (ap - ab * u).length();
}

// Predict imminent exploder kills by player tears/lasers (npc_hazards.lua:308-388).
inline bool predictExploderKillTime(const ExploderSnap& npc,
                                    const std::vector<PlayerShotTear>& tears,
                                    const std::vector<PlayerShotBeam>& beams,
                                    int maxSteps30, int& outT, bool& outBeam) {
    outT = 0;
    outBeam = false;
    int steps = std::min(maxSteps30, 30);
    if (steps <= 0) return false;
    float dmgAt[32]{};

    for (const auto& tear : tears) {
        Vec2 r0 = tear.pos - npc.pos;
        Vec2 rv = tear.vel - npc.vel;
        float hitRad = tear.size + npc.size;
        for (int t = 1; t <= steps; ++t) {
            if (!tear.aloftAt(t)) break;
            Vec2 ra = r0 + rv * static_cast<float>(t - 1);
            Vec2 rb = r0 + rv * static_cast<float>(t);
            if (pointSegDist({0.0f, 0.0f}, ra, rb) <= hitRad) {
                dmgAt[t] += tear.dmg;
                break;
            }
        }
    }

    int firstBeamT = 0;
    for (const auto& beam : beams) {
        int last = (beam.timeout > 0) ? std::min(steps, beam.timeout) : steps;
        float hitRad = npc.size + beam.size;
        for (int t = 1; t <= last; ++t) {
            Vec2 np = npc.pos + npc.vel * static_cast<float>(t);
            if (pointSegDist(np, beam.a, beam.b) <= hitRad) {
                dmgAt[t] += beam.dmg;
                if (firstBeamT == 0) firstBeamT = t;
            }
        }
    }

    float total = 0.0f;
    for (int t = 1; t <= steps; ++t) {
        total += dmgAt[t];
        if (total >= npc.hp) {
            outT = t;
            outBeam = (firstBeamT != 0 && firstBeamT <= t);
            return true;
        }
    }
    return false;
}

inline bool isTntThreatened(Vec2 tntPos, int tntState, const RoomGrid& grid,
                            const std::vector<PlayerShotTear>& tears,
                            const std::vector<Vec2>& activeNpcPos,
                            const std::vector<Vec2>& activeNpcVel,
                            const std::vector<float>& activeNpcSize,
                            const std::vector<Vec2>& liveBombPos,
                            const std::vector<float>& liveBombRad,
                            int maxSteps30) {
    int remaining = 4 - tntState;
    if (remaining <= 0) return false;
    for (size_t i = 0; i < liveBombPos.size(); ++i) {
        if ((liveBombPos[i] - tntPos).length() < liveBombRad[i] + 20.0f) return true;
    }
    int hits = 0;
    float stepsF = static_cast<float>(maxSteps30);
    for (const auto& tear : tears) {
        if (tear.dmg <= 0.0f) continue;
        // Explosive tears impacting an enemy near the barrel
        if (tear.flagsLo & IsaacEnums::kTearLoExplosive) {
            for (size_t ni = 0; ni < activeNpcPos.size(); ++ni) {
                Vec2 delta = (tear.vel - activeNpcVel[ni]) * stepsF;
                Vec2 rel = tear.pos - activeNpcPos[ni];
                float rSum = tear.size + activeNpcSize[ni];
                float a = delta.lengthSq();
                float c = rel.lengthSq() - rSum * rSum;
                float b = rel.dot(delta);
                float disc = b * b - a * c;
                float u = (c <= 0.0f) ? 0.0f : ((a > 1e-6f && disc >= 0.0f) ? (-b - std::sqrt(disc)) / a : -1.0f);
                if (u >= 0.0f && u <= 1.0f) {
                    Vec2 imp = tear.pos + tear.vel * (stepsF * u);
                    if ((tear.gridColl == 0 || grid.lineClearBullet(tear.pos, imp)) &&
                        (imp - tntPos).length() < 100.0f) {
                        return true;
                    }
                }
            }
        }
        if (tear.gridColl == 0) continue;
        // Direct hit on the 40x40 TNT cell
        Vec2 endP = tear.pos + tear.vel * stepsF;
        if (pointSegDist(tntPos, tear.pos, endP) <= 20.0f + tear.size &&
            grid.lineClearBullet(tear.pos, tntPos)) {
            if ((tear.flagsLo & IsaacEnums::kTearLoAcid) || (tear.flagsHi & IsaacEnums::kTearHiRock)) {
                return true;
            }
            if ((tear.flagsHi & IsaacEnums::kTearHiFetusBomber) == 0) {
                hits += (tear.dmg > 10.0f) ? 3 : 2;
            }
            if (hits >= remaining) return true;
        }
    }
    return false;
}

inline bool readPlayerState(const MemReader& mem, uintptr_t pPtr, PlayerState& out) {
    uint8_t dead = 0, ghost = 0, canFly = 0, ctrlEn = 1;
    int playerType = 0, subSlot = 0, ctrlCd = 0, ctrlIdx = 0;
    mem.read(pPtr + Offsets::Entity::kDead, dead);
    mem.read(pPtr + Offsets::Player::kIsCoopGhost, ghost);
    mem.read(pPtr + Offsets::Player::kPlayerType, playerType);
    mem.read(pPtr + Offsets::Player::kSubPlayerSlot, subSlot);
    mem.read(pPtr + Offsets::Player::kControlsEnabled, ctrlEn);
    mem.read(pPtr + Offsets::Player::kControlsCooldown, ctrlCd);
    mem.read(pPtr + Offsets::Player::kControllerIndex, ctrlIdx);
    mem.read(pPtr + Offsets::Player::kCanFly, canFly);
    uintptr_t subPtr = mem.readPtr32(pPtr + Offsets::Player::kSubPlayer);
    if (dead || ghost || !ctrlEn || ctrlCd > 0 || subPtr || subSlot < 0 ||
        unsupportedPlayerType(playerType)) {
        return false;
    }

    out.ptr = pPtr;
    mem.read(pPtr + Offsets::Entity::kInitSeed, out.initSeed);
    out.canFly = (canFly != 0);
    out.controllerIndex = ctrlIdx;
    mem.read(pPtr + Offsets::Entity::kPos, out.pos);
    mem.read(pPtr + Offsets::Entity::kVel, out.vel);
    mem.read(pPtr + Offsets::Entity::kSize, out.size);
    mem.read(pPtr + Offsets::Player::kMoveSpeed, out.moveSpeed);
    float dmg = 3.5f;
    if (mem.read(pPtr + Offsets::Player::kDamage, dmg) && std::isfinite(dmg) && dmg > 0.0f) {
        out.tearDamage = dmg;
    }
    uint64_t pFlags = 0;
    mem.read(pPtr + Offsets::Entity::kFlags, pFlags);
    out.slippery = (pFlags & IsaacEnums::kEntFlagSlippery) != 0;
    if (!std::isfinite(out.pos.x) || !std::isfinite(out.pos.y) ||
        !std::isfinite(out.vel.x) || !std::isfinite(out.vel.y)) {
        return false;
    }
    out.size = std::max(4.0f, std::min(40.0f, out.size));
    out.moveSpeed = std::max(0.1f, std::min(2.5f, out.moveSpeed));
    return true;
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
    if (!mem.read(mgr + Offsets::Manager::kState, mgrState) || mgrState != 2) {
        scene.paused = true;
        return false;
    }
    mem.read(mgr + Offsets::Manager::kTick60, tick60);
    scene.tick60 = tick60;

    // Paused / transition checks matching Game::IsPaused (0x6fd350) + Lua pause flag
    if (luaFlags & Shared::kFlagPaused) { scene.paused = true; return false; }
    int32_t pauseFrames = 0, soloPause = 0, overA = 0, overB = 0, cut = 0, intro = 0, scr = 0;
    uint8_t consoleOpen = 0;
    mem.read(game + Offsets::Game::kPauseFrames, pauseFrames);
    mem.read(game + Offsets::Game::kSoloMenuPause, soloPause);
    mem.read(game + Offsets::Game::kPauseOverlayA, overA);
    mem.read(game + Offsets::Game::kPauseOverlayB, overB);
    mem.read(game + Offsets::Game::kPauseCutscene, cut);
    mem.read(game + Offsets::Game::kPauseBossIntro, intro);
    mem.read(game + Offsets::Game::kPauseScreenState, scr);
    mem.read(game + Offsets::Game::kPauseConsoleOpen, consoleOpen);
    uintptr_t ctrlBeg = 0, ctrlEnd = 0;
    mem.read(mgr + Offsets::Manager::kControllersBegin, ctrlBeg);
    mem.read(mgr + Offsets::Manager::kControllersEnd, ctrlEnd);
    bool soloControllers = (ctrlEnd <= ctrlBeg) || ((ctrlEnd - ctrlBeg) <= 4u);
    if ((soloPause != 0 && soloControllers) || pauseFrames > 0 || overA || overB ||
        cut || intro || scr == 2 || consoleOpen) {
        scene.paused = true;
        return false;
    }

    mem.read(game + Offsets::Game::kFrameCount, scene.frameCount30);
    uintptr_t room = mem.readPtr32(game + Offsets::Game::kRoom);
    if (!room) { scene.passthrough = true; return false; }

    // Room-entry doorway grace: suppress overrides on the first 3 updates after room spawn (core.lua:600)
    int32_t roomSpawnFrame = 0;
    if (mem.read(room + Offsets::Room::kSpawnFrame, roomSpawnFrame)) {
        int32_t roomAge = scene.frameCount30 - roomSpawnFrame;
        if (roomAge >= 0 && roomAge < 4) {
            scene.passthrough = true;
            return false;
        }
    }

    // Locate our exact player strictly by boundSeed, plus any shared-controller twin (Jacob & Esau)
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

    if (!detail::readPlayerState(mem, myPlayer, scene.player)) {
        scene.passthrough = true; // dead/ghost/cooldown/unsupported: never fall back to stale Lua scores!
        return false;
    }

    for (size_t i = 0; i < playerCount; ++i) {
        uintptr_t pPtr = mem.readPtr32(playersBegin + i * 4u);
        if (!pPtr || pPtr == myPlayer) continue;
        PlayerState cand{};
        if (detail::readPlayerState(mem, pPtr, cand) &&
            cand.controllerIndex == scene.player.controllerIndex) {
            scene.hasTwin = true;
            scene.twin = cand;
            break;
        }
    }

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
    uint32_t seedCurses = 0, levelCurses = 0;
    mem.read(game + Offsets::Game::kDimension, dim);
    mem.read(game + Offsets::Game::kStage, stage);
    mem.read(game + Offsets::Game::kStageType, stageType);
    mem.read(game + Offsets::Game::kSeedCurses, seedCurses);
    mem.read(game + Offsets::Game::kLevelCurses, levelCurses);
    uint32_t curses = seedCurses | levelCurses;
    bool engineMirror = (dim == 1 && (stageType == 4 || stageType == 5) &&
                         (stage == 2 || (stage == 1 && (curses & 2u))));
    g.mirror = engineMirror || ((luaFlags & Shared::kFlagMirror) != 0);
    g.beast = (dataType == 16 && stageId == 35) || ((luaFlags & Shared::kFlagBeastRoom) != 0);
    // Sidescrolling non-Beast dungeons (Crawlspace / Gideon / Rotgut) use 2D gravity & ladders: hand off cleanly!
    if ((g.type == 16 || dataType == 16) && !g.beast) {
        scene.passthrough = true;
        return false;
    }
    g.beastGroundY = g.bottomRight.y - 30.0f;
    scene.deathmatch = (g.type == 30 || dataType == 30 || (luaFlags & Shared::kFlagDeathmatch) != 0);

    // Fixed world grid origin (40, 120) verified at 0x7f24a4 (holds in normal, 2x2, L-rooms, AND narrow 2/3/5/7)
    g.pitch = {40.0f, 40.0f};
    g.origin = {40.0f, 120.0f};

    // Read Room EntityList (+0x125c data*, +0x1264 count)
    uintptr_t entData = mem.readPtr32(room + Offsets::Room::kEntityData);
    uint32_t entCount = 0;
    mem.read(room + Offsets::Room::kEntityCount, entCount);
    entCount = std::min<uint32_t>(entCount, 1024u);

    // Batch-read entity pointer list once and pre-filter irrelevant entities (familiars/visual FX/etc.)
    int qDelay = std::max(0, std::min(8, queueDelay));
    scene.queueDelay30 = qDelay;
    int hMs = std::max(150, std::min(700, horizonMs > 0 ? horizonMs : 450));
    float baseUpdates = static_cast<float>(hMs) / 33.333333f;
    float playerStride30 = std::max(scene.player.vel.length(), 4.33f * scene.player.moveSpeed) * 2.0f;
    float minClearSteps = std::ceil((scene.player.size + 22.0f) / std::max(2.0f, playerStride30)) + 3.0f;
    float blastHorizon = 0.0f;
    bool sawNonPlayer = false;
    bool anyInterpolated = false;

    static_assert(Offsets::Entity::kVariant == Offsets::Entity::kType + 4u &&
                  Offsets::Entity::kSubType == Offsets::Entity::kType + 8u &&
                  Offsets::Entity::kSpawnerType == Offsets::Entity::kType + 12u,
                  "Entity type header layout");
    static_assert(Offsets::Entity::kExists == Offsets::Entity::kFlags + 10u &&
                  Offsets::Entity::kDead == Offsets::Entity::kFlags + 11u &&
                  Offsets::Entity::kInterpolated == Offsets::Entity::kFlags + 13u,
                  "Entity life block layout");

    struct EntCand {
        uintptr_t addr = 0;
        int type = 0, variant = 0, subType = 0, spawnerType = 0;
        uint64_t flags = 0;
        uint8_t dead = 0, interp = 0;
    };
    struct BombPrefetch {
        Vec2 pos{}, vel{};
        float size = 10.0f, radiusMult = 1.0f, atUpdates = -1.0f;
        int variant = 0;
    };

    std::array<uint32_t, 1024> rawEntPtrs{};
    bool entPtrBatchOk = (entCount > 0 && entData)
        ? mem.readBytes(entData, rawEntPtrs.data(), static_cast<size_t>(entCount) * 4u)
        : false;
    std::vector<EntCand> cands;
    cands.reserve(std::min<uint32_t>(entCount, 256u));
    std::vector<BombPrefetch> preBombs;
    preBombs.reserve(8);
    bool sawLiveExploder = false;

    for (uint32_t ei = 0; ei < entCount && entData; ++ei) {
        uintptr_t e = entPtrBatchOk
            ? detail::sanitizePtr32(rawEntPtrs[ei])
            : mem.readPtr32(entData + static_cast<uintptr_t>(ei) * 4u);
        if (!e || e == myPlayer) continue;

        uint8_t ex = 0, dead = 0, interp = 0;
        uint64_t flags = 0;
        if (!detail::readEntityLifeState(mem, e, flags, ex, dead, interp) || !ex) continue;

        int32_t hdr[4]{};
        if (!mem.readBytes(e + Offsets::Entity::kType, hdr, sizeof(hdr))) {
            mem.read(e + Offsets::Entity::kType, hdr[0]);
            mem.read(e + Offsets::Entity::kVariant, hdr[1]);
            mem.read(e + Offsets::Entity::kSubType, hdr[2]);
            mem.read(e + Offsets::Entity::kSpawnerType, hdr[3]);
        }
        int et = hdr[0], ev = hdr[1], esub = hdr[2], espawner = hdr[3];

        if (et != IsaacEnums::kEntPlayer) {
            sawNonPlayer = true;
            if (interp) anyInterpolated = true;
        }

        // Discard harmless/irrelevant entities before touching kPos/kVel/kSize/Parent/Sprite pages!
        if (et == IsaacEnums::kEntFamiliar) {
            if (!scene.deathmatch) continue;
        } else if (et == IsaacEnums::kEntPlayer) {
            if (!scene.deathmatch || dead) continue;
        } else if (et == IsaacEnums::kEntEffect) {
            if (detail::isHarmlessVisualEffect(ev)) continue;
            bool isPlayerCreep = detail::isPlayerCreepVariant(ev);
            if (isPlayerCreep && !scene.deathmatch) continue;
            bool ground = detail::isEnemyGroundCreep(ev) || (scene.deathmatch && isPlayerCreep);
            bool nativeCreep = ground && (ev != 195);
            if (dead && (nativeCreep || !ground)) continue;
            if (!scene.deathmatch && ((flags & IsaacEnums::kEntFlagFriendly) ||
                                      espawner == IsaacEnums::kEntPlayer ||
                                      espawner == IsaacEnums::kEntFamiliar)) {
                continue;
            }
        } else if (et == IsaacEnums::kEntBomb) {
            if (dead) continue;
            float dmg = 0.0f, mult = 1.0f;
            mem.read(e + Offsets::Bomb::kExplosionDamage, dmg);
            mem.read(e + Offsets::Bomb::kRadiusMultiplier, mult);
            if (dmg <= 0.0f) continue;
            Vec2 bPos{};
            if (!detail::readLogicPosFast(mem, e, interp != 0, bPos)) continue;
            float clampedMult = std::max(0.5f, mult);
            float bRad = ((ev == 17) ? 180.0f : 100.0f) * clampedMult;
            char bAnim[32]; float bFrame = 0.0f; bool bPlay = false, bFx = false;
            float at = -1.0f;
            if (detail::readSpriteState(mem, e + Offsets::Entity::kSprite, bAnim, sizeof(bAnim), bFrame, bPlay, bFx) &&
                std::strcmp(bAnim, "Pulse") == 0 && bFrame <= 59.0f) {
                at = std::max(0.0f, 58.0f - bFrame);
            } else {
                int32_t fuse = -1;
                mem.read(e + Offsets::Bomb::kFuse, fuse);
                if (fuse >= 0 && fuse <= 120) at = static_cast<float>(fuse);
            }
            if ((bPos - scene.player.pos).lengthSq() <= (bRad + 220.0f) * (bRad + 220.0f) &&
                at >= 0.0f && at <= 22.0f) {
                blastHorizon = std::max(blastHorizon, at + 2.0f);
            }
            Vec2 bVel{}; float bSize = 10.0f;
            uint8_t kinBuf[44]{};
            if (mem.readBytes(e + Offsets::Entity::kVel, kinBuf, sizeof(kinBuf))) {
                std::memcpy(&bVel, kinBuf, sizeof(Vec2));
                std::memcpy(&bSize, kinBuf + (Offsets::Entity::kSize - Offsets::Entity::kVel), sizeof(float));
            } else {
                mem.read(e + Offsets::Entity::kVel, bVel);
                mem.read(e + Offsets::Entity::kSize, bSize);
            }
            if (!std::isfinite(bVel.x) || !std::isfinite(bVel.y)) bVel = {0.0f, 0.0f};
            preBombs.push_back({bPos, bVel, bSize, clampedMult, at, ev});
            continue;
        } else if (et == IsaacEnums::kEntTear || et == IsaacEnums::kEntKnife ||
                   et == IsaacEnums::kEntProjectile || et == IsaacEnums::kEntLaser) {
            if (dead) continue;
            if (et == IsaacEnums::kEntProjectile && !scene.deathmatch &&
                ((flags & IsaacEnums::kEntFlagFriendly) ||
                 espawner == IsaacEnums::kEntPlayer || espawner == IsaacEnums::kEntFamiliar)) {
                continue;
            }
        } else if (et == IsaacEnums::kEntPickup) {
            // Retain pickups for pedestal/priced/chest autoAvoid check
        } else if (et >= 10 && et <= 999) {
            bool exploder = detail::isExploderNpc(et, ev);
            if (dead && !exploder) continue;
            if (et == IsaacEnums::kEntShopkeeper || et == IsaacEnums::kEntEmbryo ||
                et == IsaacEnums::kEntMovingBox || et == IsaacEnums::kEntGenericPrp ||
                et == IsaacEnums::kEntMinecart) {
                continue;
            }
            if (!scene.deathmatch && ((flags & IsaacEnums::kEntFlagFriendly) ||
                                      espawner == IsaacEnums::kEntPlayer ||
                                      espawner == IsaacEnums::kEntFamiliar)) {
                continue;
            }
            if (!dead && exploder) sawLiveExploder = true;
        } else {
            continue;
        }

        cands.push_back({e, et, ev, esub, espawner, flags, dead, interp});
    }

    if ((tick60 & 1u) != 0 && sawNonPlayer && !anyInterpolated) {
        scene.entityPhase = 0.5f;
    }

    float coreUpdates = std::min(22.0f, std::max({baseUpdates, minClearSteps, blastHorizon})) +
                        static_cast<float>(qDelay);
    int effCap = std::min(steps60Cap > 0 ? steps60Cap : 60, BulletTrack::kMaxPts - 1);
    int steps60 = std::max(10, std::min(effCap, static_cast<int>(std::ceil(coreUpdates * 2.0f))));
    scene.steps60 = steps60;
    float horizonUpdates = static_cast<float>(steps60) * 0.5f;
    int maxSteps30 = static_cast<int>(std::ceil(horizonUpdates));
    float maxReach = playerStride30 * horizonUpdates + scene.player.size + 120.0f;
    auto nearAnyPlayer = [&](Vec2 p, float extra) -> bool {
        float lim = maxReach + extra;
        float limSq = lim * lim;
        if ((p - scene.player.pos).lengthSq() <= limSq) return true;
        return scene.hasTwin && (p - scene.twin.pos).lengthSq() <= limSq;
    };

    // Populate room physical grid & static grid hazards via batched array reads
    g.cells.fill(0);
    g.hasSolidCells = false;
    bool sacrificeRoom = (g.type == 13);
    bool groundVulnerable = !scene.player.canFly || (scene.hasTwin && !scene.twin.canFly);
    struct TntCell { Vec2 pos; int state; };
    std::vector<TntCell> tntCells;

    std::array<uint32_t, Offsets::Room::kMaxGridCells> gridPtrs{};
    bool gridPtrBatch = mem.readBytes(room + Offsets::Room::kGridEntities, gridPtrs.data(),
                                      static_cast<size_t>(g.cellCount) * 4u);
    std::array<int32_t, Offsets::Room::kMaxGridCells> gridRawTypes{};
    bool gridRawLoaded = false, gridRawBatch = false;
    static_assert(Offsets::Grid::kVariant == Offsets::Grid::kType + 4u &&
                  Offsets::Grid::kState == Offsets::Grid::kType + 8u &&
                  Offsets::Grid::kCollisionClass == Offsets::Grid::kType + 56u,
                  "Grid entity header layout");

    for (int i = 0; i < g.cellCount; ++i) {
        uintptr_t ge = gridPtrBatch
            ? detail::sanitizePtr32(gridPtrs[i])
            : mem.readPtr32(room + Offsets::Room::kGridEntities + static_cast<uintptr_t>(i) * 4u);
        uint8_t cf = 0;
        if (ge) {
            int gt = 0, gv = 0, gs = 0, gc = 0;
            uint8_t gbuf[60]{};
            if (mem.readBytes(ge + Offsets::Grid::kType, gbuf, sizeof(gbuf))) {
                std::memcpy(&gt, gbuf + 0, 4);
                std::memcpy(&gv, gbuf + 4, 4);
                std::memcpy(&gs, gbuf + 8, 4);
                std::memcpy(&gc, gbuf + 56, 4);
            } else {
                mem.read(ge + Offsets::Grid::kType, gt);
                mem.read(ge + Offsets::Grid::kVariant, gv);
                mem.read(ge + Offsets::Grid::kState, gs);
                mem.read(ge + Offsets::Grid::kCollisionClass, gc);
            }
            if (gc == IsaacEnums::kGridCollWall) {
                cf |= RoomGrid::kSolidGround | RoomGrid::kSolidFly;
            } else if (gc == IsaacEnums::kGridCollPit) {
                cf |= RoomGrid::kSolidGround | RoomGrid::kPit;
            } else if (gc != IsaacEnums::kGridCollNone && gc != IsaacEnums::kGridCollWallExcept) {
                cf |= RoomGrid::kSolidGround;
                if (gc == IsaacEnums::kGridCollSolid && gt == IsaacEnums::kGridLock) {
                    cf |= RoomGrid::kSolidFly;
                }
            }

            if (gt == IsaacEnums::kGridSpikes || gt == IsaacEnums::kGridSpikesOnOff) {
                Vec2 cPos = g.cellCenter(i);
                bool active = (gt != IsaacEnums::kGridSpikesOnOff) || (gs == 0);
                if (active) {
                    char spAnim[32]; float spFrame = 0.0f; bool spPlay = false, spFx = false;
                    if (detail::readSpriteState(mem, ge + Offsets::Grid::kSprite, spAnim, sizeof(spAnim),
                                                spFrame, spPlay, spFx)) {
                        if (detail::strStartsWith(spAnim, "Unsummon") && (!spPlay || spFrame >= 11.0f)) {
                            active = false;
                        }
                    }
                }
                if (active) {
                    cf |= RoomGrid::kAutoAvoid;
                    if (sacrificeRoom) {
                        scene.discs.push_back(DiscHazard{cPos, {0, 0}, 20.0f, 0.0f, 1e6f, 0, {0, 0}, false, true, false, false});
                    } else if (groundVulnerable) {
                        scene.discs.push_back(DiscHazard{cPos, {0, 0}, 20.0f, 0.0f, 1e6f, 0, {0, 0}, false, false, false, true});
                    }
                }
            } else if (gt == IsaacEnums::kGridPoop && gv == 1 && gc != IsaacEnums::kGridCollNone) {
                Vec2 cPos = g.cellCenter(i);
                cf |= RoomGrid::kAutoAvoid;
                if (groundVulnerable) {
                    scene.discs.push_back(DiscHazard{cPos, {0, 0}, 26.0f, 0.0f, 1e6f, 0, {0, 0}, false, false, false, true});
                }
            } else if (gt == IsaacEnums::kGridRockSpiked && gc != IsaacEnums::kGridCollNone) {
                Vec2 cPos = g.cellCenter(i);
                cf |= RoomGrid::kAutoAvoid;
                scene.discs.push_back(DiscHazard{cPos, {0, 0}, 26.0f, 0.0f, 1e6f, 0});
            } else if (gt == IsaacEnums::kGridRockBomb && gs == 3) {
                Vec2 cPos = g.cellCenter(i);
                scene.discs.push_back(DiscHazard{cPos, {0, 0}, 100.0f, 0.0f, 1e6f, 1});
            } else if (gt == IsaacEnums::kGridTNT && gs < 4) {
                Vec2 cPos = g.cellCenter(i);
                if (nearAnyPlayer(cPos, 120.0f)) {
                    tntCells.push_back({cPos, gs});
                }
            }
        } else {
            if (!gridRawLoaded) {
                gridRawLoaded = true;
                gridRawBatch = mem.readBytes(room + Offsets::Room::kGridRawTypes, gridRawTypes.data(),
                                             static_cast<size_t>(g.cellCount) * 4u);
            }
            int raw = 0;
            if (gridRawBatch) {
                raw = gridRawTypes[i];
            } else {
                mem.read(room + Offsets::Room::kGridRawTypes + static_cast<uintptr_t>(i) * 4u, raw);
            }
            if (raw >= 3000 && raw <= 3999) {
                cf |= RoomGrid::kSolidGround | RoomGrid::kPit;
            } else if (raw >= 1000) {
                cf |= RoomGrid::kSolidGround;
            }
        }
        g.cells[i] = cf;
        if ((cf & (RoomGrid::kSolidGround | RoomGrid::kSolidFly)) != 0) {
            g.hasSolidCells = true;
        }
    }

    if (g.beast) {
        for (float mx = 120.0f; mx <= 680.0f; mx += 80.0f) {
            scene.discs.push_back(DiscHazard{{mx, 500.0f}, {0, 0}, 60.0f, 0.0f, 1e6f, 0});
        }
    }

    struct BombInfo {
        Vec2 pos, vel;
        float size = 10.0f;
        float baseRadius = 78.0f;
        float radiusMult = 1.0f;
        float atUpdates = 0.0f;
        float friction = 0.95f;
        Vec2 blastPos;
        Vec2 sweep{0, 0};
        bool pushed = false;
    };
    std::vector<BombInfo> bombs;
    bombs.reserve(preBombs.size());
    std::vector<Vec2> liveBombPos;
    std::vector<float> liveBombRad;
    for (const auto& pb : preBombs) {
        float warnBase = (pb.variant == 17) ? 180.0f : 100.0f;
        float hardBase = (pb.variant == 17) ? 180.0f : 78.0f;
        liveBombPos.push_back(pb.pos);
        liveBombRad.push_back(warnBase * pb.radiusMult);
        if (pb.atUpdates >= 0.0f && pb.atUpdates <= horizonUpdates + 2.0f) {
            BombInfo bi{};
            bi.pos = pb.pos; bi.vel = pb.vel; bi.size = pb.size;
            bi.baseRadius = hardBase;
            bi.radiusMult = pb.radiusMult;
            bi.atUpdates = pb.atUpdates;
            bi.friction = (pb.variant == 4) ? 1.0f : 0.95f;
            float driftScale = (bi.friction >= 1.0f) ? pb.atUpdates
                : (1.0f - std::pow(bi.friction, pb.atUpdates)) / (1.0f - bi.friction);
            bi.blastPos = bi.pos + bi.vel * driftScale;
            bombs.push_back(bi);
        }
        if (nearAnyPlayer(pb.pos, warnBase * pb.radiusMult)) {
            scene.discs.push_back(DiscHazard{pb.pos, pb.vel * 0.5f, warnBase * pb.radiusMult, 0.0f, horizonUpdates, 1});
        }
    }

    std::vector<detail::PlayerShotTear> playerTears;
    std::vector<detail::PlayerShotBeam> playerBeams;
    std::vector<detail::ExploderSnap> exploders;
    std::vector<Vec2> activeNpcPos, activeNpcVel;
    std::vector<float> activeNpcSize;

    int myCtrlIdx = scene.player.controllerIndex;
    detail::OwnedMemo ownedMemo{};
    bool needPlayerTears = sawLiveExploder || !tntCells.empty();

    static_assert(Offsets::Entity::kEntityColl == Offsets::Entity::kGridColl + 4u, "Entity coll layout");
    static_assert(Offsets::Entity::kSize == Offsets::Entity::kVel + 16u &&
                  Offsets::Entity::kSizeMulti == Offsets::Entity::kVel + 20u &&
                  Offsets::Entity::kHitPoints == Offsets::Entity::kVel + 32u &&
                  Offsets::Entity::kCollDamage == Offsets::Entity::kVel + 40u,
                  "Entity kinematics block layout");
    static_assert(Offsets::Tear::kFallingSpeed == Offsets::Tear::kHeight + 4u &&
                  Offsets::Tear::kFallingAccel == Offsets::Tear::kHeight + 8u &&
                  Offsets::Tear::kFlagsLo == Offsets::Tear::kHeight + 24u &&
                  Offsets::Tear::kFlagsHi == Offsets::Tear::kHeight + 32u,
                  "Tear block layout");

    for (const EntCand& c : cands) {
        const uintptr_t e = c.addr;
        const int eType = c.type;
        const int eVar = c.variant;
        const int eSub = c.subType;
        const uint8_t eDead = c.dead;
        const uint64_t eFlags = c.flags;

        if (eType == IsaacEnums::kEntTear && !scene.deathmatch && !needPlayerTears) {
            continue;
        }

        Vec2 ePos{};
        if (eType == IsaacEnums::kEntPlayer) {
            if (!mem.read(e + Offsets::Entity::kPos, ePos) || !std::isfinite(ePos.x) || !std::isfinite(ePos.y)) continue;
        } else {
            if (!detail::readLogicPosFast(mem, e, c.interp != 0, ePos)) continue;
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

        Vec2 eVel{};
        Vec2 eSizeMulti{1.0f, 1.0f};
        float eSize = 10.0f, eHp = 10.0f, eCollDmg = 0.0f;
        uint8_t kinBuf[44]{};
        if (mem.readBytes(e + Offsets::Entity::kVel, kinBuf, sizeof(kinBuf))) {
            std::memcpy(&eVel, kinBuf, sizeof(Vec2));
            std::memcpy(&eSize, kinBuf + 16, sizeof(float));
            std::memcpy(&eSizeMulti, kinBuf + 20, sizeof(Vec2));
            std::memcpy(&eHp, kinBuf + 32, sizeof(float));
            std::memcpy(&eCollDmg, kinBuf + 40, sizeof(float));
        } else {
            mem.read(e + Offsets::Entity::kVel, eVel);
            mem.read(e + Offsets::Entity::kSize, eSize);
            mem.read(e + Offsets::Entity::kSizeMulti, eSizeMulti);
            mem.read(e + Offsets::Entity::kHitPoints, eHp);
            mem.read(e + Offsets::Entity::kCollDamage, eCollDmg);
        }

        // Deathmatch opponent player (excluding boundSeed & shared-controller twin Esau)
        if (eType == IsaacEnums::kEntPlayer) {
            if (scene.deathmatch && !eDead && !detail::isOurSidePlayer(mem, e, boundSeed, myCtrlIdx)) {
                scene.discs.push_back(DiscHazard{ePos, eVel, eSize + 3.0f, 0.0f, horizonUpdates, 0,
                                                 {0, 0}, false, false, true});
            }
            continue;
        }

        // Hostile / Deathmatch opponent ENTITY_KNIFE (Type 8)
        if (eType == IsaacEnums::kEntKnife) {
            if (!detail::isPlayerOwnedFast(mem, e, eType, c.spawnerType, eFlags, scene.deathmatch, boundSeed, myCtrlIdx, &ownedMemo)) {
                scene.discs.push_back(DiscHazard{ePos, eVel, std::max(24.0f, eSize), 0.0f, horizonUpdates, 0});
            }
            continue;
        }

        if (eType == IsaacEnums::kEntLaser) {
            uint8_t oneHit = 0, firstUpd = 1, shrink = 0;
            int timeout = 0;
            mem.read(e + Offsets::Laser::kOneHit, oneHit);
            mem.read(e + Offsets::Laser::kFirstUpdate, firstUpd);
            mem.read(e + Offsets::Laser::kShrink, shrink);
            mem.read(e + Offsets::Laser::kTimeout, timeout);
            // Fading OneHit / shrinking beams deal 0 damage (0x973f66)
            if (shrink != 0 || (oneHit != 0 && firstUpd == 0)) continue;

            uint8_t subType = static_cast<uint8_t>(eSub);
            bool isCircle = (subType == 1 || subType == 2 || subType == 3);
            if (detail::isPlayerOwnedFast(mem, e, eType, c.spawnerType, eFlags, scene.deathmatch, boundSeed, myCtrlIdx, &ownedMemo)) {
                if (!isCircle) {
                    Vec2 endPt = ePos;
                    mem.read(e + Offsets::Laser::kEndPoint, endPt);
                    playerBeams.push_back({ePos, endPt, std::max(8.0f, eSize),
                                           eCollDmg > 0.0f ? eCollDmg : scene.player.tearDamage, timeout});
                }
                continue;
            }
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
            lh.ring = isCircle;
            mem.read(e + Offsets::Laser::kRadius, lh.radius);
            lh.width = std::max(8.0f, eSize) + 4.0f;
            if (timeout > 0) {
                lh.timeoutT = std::max(0.5f, static_cast<float>(timeout));
            }
            if (isRot) {
                int rDel = 0;
                mem.read(e + Offsets::Laser::kRotationSpd, lh.angularSpeed);
                mem.read(e + Offsets::Laser::kRotationDelay, rDel);
                lh.rotDelay = std::max(0, rDel);
            }
            if (!lh.ring) {
                uintptr_t sb = mem.readPtr32(e + Offsets::Laser::kSamplesBegin);
                uintptr_t se = mem.readPtr32(e + Offsets::Laser::kSamplesEnd);
                size_t count = (sb && se > sb) ? ((se - sb) / sizeof(Vec2)) : 0;
                if (count >= 2 && count <= 512) {
                    int nOut = 0;
                    size_t stride = (count <= LaserHazard::kMaxSamples)
                        ? 1u
                        : ((count + LaserHazard::kMaxSamples - 2u) / (LaserHazard::kMaxSamples - 1u));
                    for (size_t si = 0; si < count && nOut < LaserHazard::kMaxSamples - 1; si += stride) {
                        Vec2 pt{};
                        if (mem.read(sb + si * sizeof(Vec2), pt) && std::isfinite(pt.x)) {
                            Vec2 rel = pt - lh.origin;
                            lh.pts[nOut++] = rel;
                            lh.reach = std::max(lh.reach, rel.length());
                        }
                    }
                    Vec2 lastPt{};
                    if (mem.read(sb + (count - 1u) * sizeof(Vec2), lastPt) && std::isfinite(lastPt.x)) {
                        Vec2 rel = lastPt - lh.origin;
                        if (nOut == 0 || (lh.pts[nOut - 1] - rel).lengthSq() > 0.25f) {
                            lh.pts[nOut++] = rel;
                            lh.reach = std::max(lh.reach, rel.length());
                        }
                    }
                    lh.numPts = nOut;
                } else {
                    Vec2 endPt{};
                    float ang = 0.0f, maxDist = 0.0f;
                    mem.read(e + Offsets::Laser::kEndPoint, endPt);
                    mem.read(e + Offsets::Laser::kAngleDeg, ang);
                    mem.read(e + Offsets::Laser::kLaserLength, maxDist);
                    Vec2 rel = endPt - lh.origin;
                    if (rel.lengthSq() < 4.0f || !std::isfinite(rel.x)) {
                        float len = (maxDist > 1.0f) ? maxDist : 800.0f;
                        rel = Vec2{len, 0.0f}.rotatedDeg(ang);
                    }
                    lh.pts[0] = {0.0f, 0.0f};
                    lh.pts[1] = rel;
                    lh.numPts = 2;
                    lh.reach = rel.length();
                }
            }
            scene.lasers.push_back(lh);
            if (!lh.ring && parentNpc && lh.numPts >= 2) {
                LaserHazard band = lh;
                band.width += 28.0f;
                band.warning = 1;
                scene.lasers.push_back(band);
            }
            continue;
        }

        if (eType == IsaacEnums::kEntEffect) {
            bool isPlayerCreep = detail::isPlayerCreepVariant(eVar);
            bool ground = detail::isEnemyGroundCreep(eVar) || (scene.deathmatch && isPlayerCreep);
            bool nativeCreep = ground && (eVar != 195);
            if (detail::isPlayerOwnedFast(mem, e, eType, c.spawnerType, eFlags, scene.deathmatch, boundSeed, myCtrlIdx, &ownedMemo)) {
                continue;
            }

            if (eVar == 110 && !eDead) { // ENEMY_BRIMSTONE_SWIRL cardinal laser warning
                char sAnim[32]; float sFrame = 0.0f; bool sPlay = false, sFx = false;
                if (detail::readSpriteState(mem, e + Offsets::Entity::kSprite, sAnim, sizeof(sAnim), sFrame, sPlay, sFx) &&
                    std::strcmp(sAnim, "IdleQuick") == 0) {
                    float af = std::max(0.5f, 24.0f - sFrame);
                    float diag = std::max(600.0f, (g.bottomRight - g.topLeft).length());
                    for (float ang : {0.0f, 90.0f, 180.0f, 270.0f}) {
                        detail::addDirectedLaser(scene.lasers, ePos, eVel, ang, diag, 24.0f, af, false);
                    }
                }
            }

            bool warnEff = false;
            float baseAreaR = detail::areaEffectBaseRadius(eVar, warnEff);
            if (ground) {
                if (!groundVulnerable) continue;
                Vec2 sprScale{1.0f, 1.0f};
                float effScale = 1.0f;
                mem.read(e + Offsets::Entity::kSpriteScale, sprScale);
                mem.read(e + Offsets::Effect::kScale, effScale);
                float pSpeed = scene.player.vel.length() * 2.0f;
                float r = nativeCreep
                    ? (eSize * std::abs(sprScale.x) + 12.0f + pSpeed)
                    : (std::max(eSize * std::max(std::abs(eSizeMulti.x), std::abs(eSizeMulti.y)),
                                24.0f * std::max(0.5f, effScale)) + 12.0f + pSpeed);
                if (nearAnyPlayer(ePos, r)) {
                    scene.discs.push_back(DiscHazard{ePos, eVel, r, 0.0f, horizonUpdates, 0,
                                                     {0, 0}, false, false, false, true});
                }
            } else if (baseAreaR > 0.0f || eCollDmg > 0.0f) {
                float effScale = 1.0f;
                int timeout = 0;
                mem.read(e + Offsets::Effect::kScale, effScale);
                mem.read(e + Offsets::Effect::kTimeout, timeout);
                float maxT = (timeout > 0) ? std::min(horizonUpdates, static_cast<float>(timeout)) : horizonUpdates;
                float hitR = eSize * std::max(std::abs(eSizeMulti.x), std::abs(eSizeMulti.y));
                float r = std::max(hitR, (baseAreaR > 0.0f ? baseAreaR : 24.0f) * std::max(0.5f, effScale));
                if (nearAnyPlayer(ePos, r)) {
                    scene.discs.push_back(DiscHazard{ePos, eVel, r, 0.0f, maxT, static_cast<uint8_t>(warnEff ? 1 : 0)});
                }
            }
            continue;
        }

        // Remaining types (Tear, Projectile, NPC) use kGridColl & kEntityColl
        int eGridColl = 3, eEntityColl = 0;
        int32_t collPair[2]{};
        if (mem.readBytes(e + Offsets::Entity::kGridColl, collPair, sizeof(collPair))) {
            eGridColl = collPair[0];
            eEntityColl = collPair[1];
        } else {
            mem.read(e + Offsets::Entity::kGridColl, eGridColl);
            mem.read(e + Offsets::Entity::kEntityColl, eEntityColl);
        }

        if (eType == IsaacEnums::kEntTear) {
            bool owned = detail::isPlayerOwnedFast(mem, e, eType, c.spawnerType, eFlags, scene.deathmatch, boundSeed, myCtrlIdx, &ownedMemo);
            if (owned) {
                detail::PlayerShotTear pt{};
                pt.pos = ePos; pt.vel = eVel; pt.size = eSize;
                pt.dmg = eCollDmg > 0.0f ? eCollDmg : scene.player.tearDamage;
                pt.gridColl = eGridColl;
                uint8_t tBuf[40]{};
                if (mem.readBytes(e + Offsets::Tear::kHeight, tBuf, sizeof(tBuf))) {
                    std::memcpy(&pt.height, tBuf + 0, 4);
                    std::memcpy(&pt.fallSpeed, tBuf + 4, 4);
                    std::memcpy(&pt.fallAccel, tBuf + 8, 4);
                    std::memcpy(&pt.flagsLo, tBuf + 24, 8);
                    std::memcpy(&pt.flagsHi, tBuf + 32, 8);
                } else {
                    mem.read(e + Offsets::Tear::kHeight, pt.height);
                    mem.read(e + Offsets::Tear::kFallingSpeed, pt.fallSpeed);
                    mem.read(e + Offsets::Tear::kFallingAccel, pt.fallAccel);
                    mem.read(e + Offsets::Tear::kFlagsLo, pt.flagsLo);
                    mem.read(e + Offsets::Tear::kFlagsHi, pt.flagsHi);
                }
                playerTears.push_back(pt);
            } else if (scene.deathmatch && scene.bullets.size() < 256) {
                float h = -23.0f, fs = 0.0f, fa = 0.0f;
                mem.read(e + Offsets::Tear::kHeight, h);
                mem.read(e + Offsets::Tear::kFallingSpeed, fs);
                mem.read(e + Offsets::Tear::kFallingAccel, fa);
                BulletTrack tr{};
                detail::simulateBulletCommon(ePos, eVel, eSize, 1.0f, 0.0f, 0.0f, 1, eGridColl,
                                             h, fs, fa, 0.0f, 0.0f, 1.0f,
                                             IsaacEnums::kProjAnyHeightHit, 0, 0, 0.0f, 0,
                                             scene.player.pos, scene, horizonUpdates, steps60, tr, scene.discs);
                if (tr.lastStep >= tr.firstStep && tr.lastStep >= 0) scene.bullets.push_back(tr);
            }
            continue;
        }

        if (eType == IsaacEnums::kEntProjectile) {
            if (detail::isPlayerOwnedFast(mem, e, eType, c.spawnerType, eFlags, scene.deathmatch, boundSeed, myCtrlIdx, &ownedMemo)) {
                continue;
            }
            uint64_t pFlags = 0;
            float fallAcc = 0.0f;
            mem.read(e + Offsets::Projectile::kFlags, pFlags);
            mem.read(e + Offsets::Projectile::kFallingAccel, fallAcc);
            if (pFlags & IsaacEnums::kProjExplode) {
                scene.discs.push_back(DiscHazard{ePos, eVel, 100.0f, 0.0f, horizonUpdates, 1});
            }
            bool collidable = (eEntityColl != IsaacEnums::kEntCollNone &&
                               eEntityColl != IsaacEnums::kEntCollEnemies);
            bool arcing = (eEntityColl == IsaacEnums::kEntCollNone && fallAcc > 0.05f);
            if ((collidable || arcing) && scene.bullets.size() < 256) {
                BulletTrack tr{};
                detail::simulateProjectilePreloaded(mem, e, ePos, eVel, eSize, c.spawnerType, eGridColl,
                                                    scene, horizonUpdates, steps60, tr, scene.discs);
                if (tr.lastStep >= tr.firstStep && tr.lastStep >= 0) scene.bullets.push_back(tr);
            }
            continue;
        }

        // NPCs (10..999)
        if (detail::isPlayerOwnedFast(mem, e, eType, c.spawnerType, eFlags, scene.deathmatch, boundSeed, myCtrlIdx, &ownedMemo)) {
            continue;
        }

        if (eDead) {
            if (detail::isExploderNpc(eType, eVar)) {
                char dAnim[32]; float dFrame = 0.0f; bool dPlay = false, dFx = false;
                if (detail::readSpriteState(mem, e + Offsets::Entity::kSprite, dAnim, sizeof(dAnim), dFrame, dPlay, dFx) &&
                    std::strcmp(dAnim, "Explode") == 0) {
                    detail::ExploderSnap es{};
                    es.pos = ePos; es.vel = {0, 0}; es.size = eSize;
                    es.type = eType; es.variant = eVar; es.dead = true;
                    es.animFrame = dFrame; es.animExplode = true;
                    exploders.push_back(es);
                }
            }
            continue;
        }

        uint8_t isBoss = 0;
        mem.read(e + Offsets::NPC::kIsBoss, isBoss);
        bool activeEnemy = detail::isActiveEnemyRaw(eType, eVar, eDead, eFlags);
        bool contactableColl = (eEntityColl == IsaacEnums::kEntCollPlayerOnly ||
                                eEntityColl == IsaacEnums::kEntCollPlayerObjects ||
                                eEntityColl == IsaacEnums::kEntCollAll);
        if (activeEnemy && (eEntityColl == IsaacEnums::kEntCollPlayerObjects || eEntityColl == IsaacEnums::kEntCollAll)) {
            activeNpcPos.push_back(ePos);
            activeNpcVel.push_back(eVel);
            activeNpcSize.push_back(eSize);
        }

        // Chubber boomerang worm (39.22.0): model via exact StateFrame=0..42 tethered BulletTrack
        // instead of an unbounded linear Pos + Vel*t DiscHazard.
        if (eType == IsaacEnums::kEntVis && eVar == 22 && contactableColl && eCollDmg > 0.0f &&
            (activeEnemy || (isBoss != 0)) && scene.bullets.size() < 256) {
            BulletTrack wormTrack{};
            detail::simulateChubberWorm(mem, e, ePos, eVel, eSize, scene, steps60, wormTrack);
            if (wormTrack.lastStep >= wormTrack.firstStep && wormTrack.lastStep >= 0) {
                scene.bullets.push_back(wormTrack);
            }
            continue;
        }

        if (contactableColl && eCollDmg > 0.0f &&
            (eType == IsaacEnums::kEntFireplace || activeEnemy || (isBoss != 0))) {
            if (nearAnyPlayer(ePos, eSize + 32.0f + eVel.length() * horizonUpdates)) {
                scene.discs.push_back(DiscHazard{ePos, eVel, eSize + 3.0f, 0.0f, horizonUpdates, 0,
                                                 {0, 0}, false, false, eType != IsaacEnums::kEntFireplace});
                float spdBuf = std::min(16.0f, eVel.length() * 2.0f);
                if (spdBuf > 1.0f) {
                    scene.discs.push_back(DiscHazard{ePos, eVel, eSize + 5.0f + spdBuf, 0.0f, horizonUpdates, 1});
                }
            }
        }

        if (!activeEnemy) continue;

        if (detail::isExploderNpc(eType, eVar)) {
            detail::ExploderSnap es{};
            es.pos = ePos; es.vel = eVel; es.size = eSize; es.hp = eHp;
            es.type = eType; es.variant = eVar; es.dead = false;
            exploders.push_back(es);
        }

        detail::appendNpcIntentWarnings(mem, e, eType, eVar, eSize, ePos, eVel, scene, horizonUpdates, scene.discs, scene.lasers);
    }

    // Resolve exploder death bursts & imminent killTime (npc_hazards.lua:345-390)
    for (const auto& ex : exploders) {
        float burstR = (ex.type == IsaacEnums::kEntBoomFly && ex.variant == 6) ? 100.0f : 75.0f;
        if (ex.dead) {
            float rem = std::min(horizonUpdates, std::max(1.0f, 30.0f - ex.animFrame));
            scene.discs.push_back(DiscHazard{ex.pos, {0, 0}, burstR, 0.0f, rem, 0});
            if (ex.type == IsaacEnums::kEntBoomFly && ex.variant == 6) {
                float cf = std::max(1.0f, 25.0f - ex.animFrame);
                if (cf <= horizonUpdates) {
                    for (float ang : {0.0f, 90.0f, 180.0f, 270.0f}) {
                        detail::addDirectedLaser(scene.lasers, ex.pos, {0, 0}, ang, 600.0f, 24.0f, cf, true);
                    }
                }
            }
        } else {
            int killT = 0;
            bool byBeam = false;
            if (detail::predictExploderKillTime(ex, playerTears, playerBeams, maxSteps30, killT, byBeam)) {
                float early = byBeam ? 3.0f : 2.0f;
                float late  = byBeam ? 3.0f : 1.0f;
                float kt = static_cast<float>(killT);
                scene.discs.push_back(DiscHazard{ex.pos, ex.vel, burstR,
                                                 std::max(0.0f, kt - early), kt + late, 0});
                if (ex.type == IsaacEnums::kEntBoomFly && ex.variant == 6) {
                    Vec2 deathPos = ex.pos + ex.vel * kt;
                    for (float ang : {0.0f, 90.0f, 180.0f, 270.0f}) {
                        detail::addDirectedLaser(scene.lasers, deathPos, {0, 0}, ang, 600.0f, 24.0f, kt, true);
                    }
                }
            } else if (ex.hp <= std::max(3.5f, scene.player.tearDamage * 2.0f) ||
                       detail::isChaserExploder(ex.type, ex.variant)) {
                scene.discs.push_back(DiscHazard{ex.pos, ex.vel, burstR, 0.0f, horizonUpdates, 1});
            }
        }
    }

    // Resolve threatened TNT barrels (tnt_hazards.lua:123-154)
    for (const auto& tc : tntCells) {
        if (detail::isTntThreatened(tc.pos, tc.state, g, playerTears,
                                    activeNpcPos, activeNpcVel, activeNpcSize,
                                    liveBombPos, liveBombRad, maxSteps30)) {
            scene.discs.push_back(DiscHazard{tc.pos, {0, 0}, 100.0f, 0.0f, horizonUpdates, 1});
        }
    }

    // Bomb chain knockback resolution (capsule sweep [blastPos, blastPos + sweep], core.lua:428-431)
    if (!bombs.empty()) {
        std::sort(bombs.begin(), bombs.end(), [](const BombInfo& a, const BombInfo& b) {
            return a.atUpdates < b.atUpdates;
        });
        size_t chainMax = std::min<size_t>(bombs.size(), 8);
        for (size_t i = 0; i < chainMax; ++i) {
            float br = bombs[i].baseRadius * bombs[i].radiusMult;
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
                        bombs[j].radiusMult += slideDist / bombs[j].baseRadius;
                    } else {
                        bombs[j].sweep += away.normalized() * slideDist;
                    }
                    bombs[j].pushed = true;
                }
            }
            float early = bombs[i].pushed ? 2.0f : 1.0f;
            float late  = bombs[i].pushed ? 2.0f : 1.0f;
            bool hasSweep = bombs[i].sweep.lengthSq() > 0.25f;
            scene.discs.push_back(DiscHazard{
                bombs[i].blastPos,
                {0.0f, 0.0f},
                bombs[i].baseRadius * bombs[i].radiusMult,
                std::max(0.0f, bombs[i].atUpdates - early),
                bombs[i].atUpdates + late,
                0,
                hasSweep ? bombs[i].sweep : Vec2{0.0f, 0.0f},
                hasSweep,
                false,
                false
            });
        }
    }

    scene.valid = true;
    return true;
}

} // namespace iad
