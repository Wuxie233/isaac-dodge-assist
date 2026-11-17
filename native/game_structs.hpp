#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace iad {

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;

    Vec2() = default;
    constexpr Vec2(float x_, float y_) : x(x_), y(y_) {}

    Vec2 operator+(const Vec2& o) const { return {x + o.x, y + o.y}; }
    Vec2 operator-(const Vec2& o) const { return {x - o.x, y - o.y}; }
    Vec2 operator*(float s) const { return {x * s, y * s}; }
    Vec2& operator+=(const Vec2& o) { x += o.x; y += o.y; return *this; }
    Vec2& operator-=(const Vec2& o) { x -= o.x; y -= o.y; return *this; }
    Vec2& operator*=(float s) { x *= s; y *= s; return *this; }

    float lengthSq() const { return x * x + y * y; }
    float length() const { return std::sqrt(lengthSq()); }
    float dot(const Vec2& o) const { return x * o.x + y * o.y; }
    float cross(const Vec2& o) const { return x * o.y - y * o.x; }

    Vec2 normalized() const {
        float l = length();
        return l > 1e-6f ? Vec2{x / l, y / l} : Vec2{0.0f, 0.0f};
    }

    Vec2 resized(float n) const {
        float l = length();
        return l > 1e-6f ? Vec2{x * (n / l), y * (n / l)} : Vec2{0.0f, 0.0f};
    }

    Vec2 rotatedDeg(float deg) const {
        constexpr float kDegToRad = 0.017453292519943295f;
        float r = deg * kDegToRad;
        float c = std::cos(r);
        float s = std::sin(r);
        return {x * c - y * s, x * s + y * c};
    }
};

// Shared IPC memory layout. Bytes 0..127 remain binary-identical to v1 (0.4.x).
// Extended v2 fields live at bytes 128..191 and are active only when mapped
// region size >= sizeof(Shared) and extMagic == kExtMagic.
struct Shared {
    static constexpr uint32_t kMagic = 0x32444149u;    // "IAD2"
    static constexpr uint32_t kExtMagic = 0x4E415432u; // "NAT2"
    static constexpr uint32_t kFlagNativeEnabled = 1u << 0;
    static constexpr uint32_t kFlagMirror        = 1u << 1;
    static constexpr uint32_t kFlagDeathmatch    = 1u << 2;
    static constexpr uint32_t kFlagBeastRoom     = 1u << 3;
    static constexpr uint32_t kFlagPaused        = 1u << 4;

#ifdef _WIN32
    using IpcLong = long;
#else
    using IpcLong = int32_t;
#endif
    static_assert(sizeof(IpcLong) == 4, "IPC atomic fields must be 32-bit");

    uint32_t magic;
    int32_t version;
    uint32_t pid;
    uint32_t stamp;
    int32_t active;
    int32_t blocked;
    int32_t sequence;
    uint32_t combat;
    double risk[9];
    volatile IpcLong status;
    volatile IpcLong polls;
    volatile IpcLong overrides;
    volatile IpcLong chosen;
    volatile IpcLong shots;
    uint32_t padV1;

    // Extended v2 block (bytes 128..191)
    uint32_t extMagic;
    uint32_t boundSeed;
    uint32_t luaFlags;
    int32_t horizonMs;
    int32_t queueDelay;
    volatile IpcLong nativeMode;    // 0=Lua/idle, 1=Native60Hz, 2=NativeFallback
    volatile IpcLong nativeThreats;
    volatile IpcLong nativeMicros;
    volatile IpcLong nativeFrames;
    volatile IpcLong nativeChosen;  // bit 4 (16) set when 2-stage turn planned
    int32_t reservedV2[6];
};

static_assert(offsetof(Shared, risk) == 32, "Shared v1 offset risk");
static_assert(offsetof(Shared, status) == 104, "Shared v1 offset status");
static_assert(offsetof(Shared, shots) == 120, "Shared v1 offset shots");
static_assert(offsetof(Shared, extMagic) == 128, "Shared v2 offset extMagic");
static_assert(sizeof(Shared) == 192, "Shared size");

// Binary-verified offsets for isaac-ng.exe:
// TimeDateStamp = 0x69e6e3a7, SizeOfImage = 0x92c000.
namespace Offsets {
    static constexpr uint32_t kExpectedTimestamp = 0x69e6e3a7u;
    static constexpr uint32_t kExpectedImageSize = 0x92c000u;

    static constexpr uintptr_t kManagerRva = 0x87169cu;
    static constexpr uintptr_t kGameRva    = 0x871678u;
    static constexpr uintptr_t kLRoomTableRva = 0x835b80u;

    namespace Manager {
        static constexpr uintptr_t kState   = 0x8u;     // int32 (2 = in run)
        static constexpr uintptr_t kTick60  = 0x4abbcu; // uint32 (bit 0 = interp tick)
    }

    namespace Game {
        static constexpr uintptr_t kStage        = 0x0u;
        static constexpr uintptr_t kStageType    = 0x4u;
        static constexpr uintptr_t kRoom         = 0x18300u;
        static constexpr uintptr_t kDimension    = 0x1830cu;
        static constexpr uintptr_t kPlayersBegin = 0x1baa8u;
        static constexpr uintptr_t kPlayersEnd   = 0x1baacu;
        static constexpr uintptr_t kPauseB83C    = 0x1b83cu;
        static constexpr uintptr_t kPauseBA78    = 0x1ba78u;
        static constexpr uintptr_t kPauseC034    = 0x1c034u;
        static constexpr uintptr_t kPauseD520    = 0x1d520u;
        static constexpr uintptr_t kPauseD654    = 0x1d654u;
        static constexpr uintptr_t kPause25954   = 0x25954u;
        static constexpr uintptr_t kPauseFrames  = 0x264f4u;
        static constexpr uintptr_t kFrameCount   = 0x264f8u;
        static constexpr uintptr_t kCurses       = 0x26550u;
        static constexpr uintptr_t kGameModeFlags= 0x26614u;
        static constexpr uintptr_t kPause68D78   = 0x68d78u;
    }

    namespace Room {
        static constexpr uintptr_t kDescriptor    = 0x4u;    // Descriptor* -> +0x10 Data*
        static constexpr uintptr_t kDescData      = 0x10u;   // RoomConfig_Room*
        static constexpr uintptr_t kDataStageId   = 0x0u;    // 35 = Beast room when Type==16
        static constexpr uintptr_t kDataType      = 0x8u;
        static constexpr uintptr_t kDataShape     = 0x48u;
        static constexpr uintptr_t kType          = 0x8u;
        static constexpr uintptr_t kGridWidth     = 0xcu;
        static constexpr uintptr_t kGridHeight    = 0x10u;
        static constexpr uintptr_t kTopLeft       = 0x14u;   // Vec2
        static constexpr uintptr_t kBottomRight   = 0x1cu;   // Vec2
        static constexpr uintptr_t kGridEntities  = 0x24u;   // GridEntity*[448]
        static constexpr uintptr_t kGridRawTypes  = 0x76cu;  // int32[448]
        static constexpr uintptr_t kEntityData    = 0x125cu; // Entity**
        static constexpr uintptr_t kEntityCount   = 0x1264u; // uint32
        static constexpr int kMaxGridCells        = 448;
    }

    namespace Sprite {
        static constexpr uintptr_t kAnimData      = 0x34u; // ptr -> MSVC std::string at +0x0
        static constexpr uintptr_t kFrame         = 0x40u; // float (floor -> frame)
        static constexpr uintptr_t kPlaying       = 0x44u; // uint8
        static constexpr uintptr_t kOffset        = 0x94u; // Vec2
        static constexpr uintptr_t kFlipX         = 0x100u;// uint8
        static constexpr uintptr_t kFlipY         = 0x101u;// uint8
        static constexpr uintptr_t kPlaybackSpeed = 0x104u;// float
    }

    namespace Entity {
        static constexpr uintptr_t kType          = 0x28u;
        static constexpr uintptr_t kVariant       = 0x2cu;
        static constexpr uintptr_t kSubType       = 0x30u;
        static constexpr uintptr_t kSpawnerType   = 0x34u;
        static constexpr uintptr_t kSprite        = 0x48u;  // inline Sprite
        static constexpr uintptr_t kSpriteOffset  = 0xdcu;  // Vec2
        static constexpr uintptr_t kFlags         = 0x168u; // uint64
        static constexpr uintptr_t kExists        = 0x172u; // uint8
        static constexpr uintptr_t kDead          = 0x173u; // uint8
        static constexpr uintptr_t kInterpolated  = 0x175u; // uint8
        static constexpr uintptr_t kGridColl      = 0x184u; // int32
        static constexpr uintptr_t kEntityColl    = 0x188u; // int32
        static constexpr uintptr_t kSpawnFrame    = 0x328u; // int32
        static constexpr uintptr_t kPos           = 0x33cu; // Vec2
        static constexpr uintptr_t kInterpPrevPos = 0x344u; // Vec2
        static constexpr uintptr_t kVel           = 0x360u; // Vec2
        static constexpr uintptr_t kFriction      = 0x36cu; // float
        static constexpr uintptr_t kSize          = 0x370u; // float
        static constexpr uintptr_t kSizeMulti     = 0x374u; // Vec2
        static constexpr uintptr_t kHitPoints     = 0x380u; // float
        static constexpr uintptr_t kMaxHitPoints  = 0x384u; // float
        static constexpr uintptr_t kCollDamage    = 0x388u; // float
        static constexpr uintptr_t kTimeScale     = 0x39cu; // float
        static constexpr uintptr_t kAgeFloat      = 0x3a4u; // float
        static constexpr uintptr_t kParent        = 0x3bcu; // ptr
        static constexpr uintptr_t kChild         = 0x3c0u; // ptr
        static constexpr uintptr_t kTarget        = 0x3c4u; // ptr
        static constexpr uintptr_t kSpawnerEntity = 0x3c8u; // ptr
        static constexpr uintptr_t kInitSeed      = 0x3ecu; // uint32
    }

    namespace Player {
        static constexpr uintptr_t kControlsEnabled  = 0x410u; // uint8
        static constexpr uintptr_t kControlsCooldown = 0x414u; // int32
        static constexpr uintptr_t kPlayerType       = 0x13c0u;// int32
        static constexpr uintptr_t kMaxFireDelay     = 0x1460u;// float
        static constexpr uintptr_t kMoveSpeed        = 0x1568u;// float
        static constexpr uintptr_t kCanFly           = 0x1570u;// uint8
        static constexpr uintptr_t kControllerIndex  = 0x1618u;// int32
        static constexpr uintptr_t kSubPlayerSlot    = 0x161cu;// int32 (<0 -> IsSubPlayer)
        static constexpr uintptr_t kSubPlayer        = 0x1d98u;// ptr
        static constexpr uintptr_t kIsCoopGhost      = 0x20a9u;// uint8
    }

    namespace Projectile {
        static constexpr uintptr_t kHeight          = 0x410u; // float
        static constexpr uintptr_t kFallingSpeed    = 0x414u; // float
        static constexpr uintptr_t kFallingAccel    = 0x418u; // float
        static constexpr uintptr_t kScale           = 0x420u; // float
        static constexpr uintptr_t kHomingStrength  = 0x424u; // float
        static constexpr uintptr_t kCurvingStrength = 0x428u; // float
        static constexpr uintptr_t kAcceleration    = 0x42cu; // float
        static constexpr uintptr_t kFlags           = 0x438u; // uint64
        static constexpr uintptr_t kWiggleOffset    = 0x448u; // int32
        static constexpr uintptr_t kChangeFlags     = 0x450u; // uint64
        static constexpr uintptr_t kChangeVelocity  = 0x458u; // float
        static constexpr uintptr_t kChangeTimeout   = 0x45cu; // int32
    }

    namespace NPC {
        static constexpr uintptr_t kStateFrame = 0x410u; // int32
        static constexpr uintptr_t kState      = 0xb64u; // int32
        static constexpr uintptr_t kProjCd     = 0xba0u; // int32
        static constexpr uintptr_t kProjDelay  = 0xba4u; // int32
        static constexpr uintptr_t kV1         = 0xbb0u; // Vec2
        static constexpr uintptr_t kV2         = 0xbb8u; // Vec2
        static constexpr uintptr_t kI1         = 0xbc0u; // int32
        static constexpr uintptr_t kI2         = 0xbc4u; // int32
        static constexpr uintptr_t kIsBoss     = 0xc3du; // uint8
    }

    namespace Laser {
        static constexpr uintptr_t kStartAngleDeg      = 0x418u; // float
        static constexpr uintptr_t kAngleDeg           = 0x41cu; // float
        static constexpr uintptr_t kLastAngleDeg       = 0x420u; // float
        static constexpr uintptr_t kTimeout            = 0x458u; // int32
        static constexpr uintptr_t kLaserLength        = 0x460u; // float
        static constexpr uintptr_t kSamplesBegin       = 0x480u; // Vec2*
        static constexpr uintptr_t kSamplesEnd         = 0x484u; // Vec2*
        static constexpr uintptr_t kCurveStrength      = 0x4b8u; // float
        static constexpr uintptr_t kRadius             = 0x4bcu; // float
        static constexpr uintptr_t kIsActiveRotating   = 0x4c0u; // uint8
        static constexpr uintptr_t kRotationDelay      = 0x4c4u; // int32
        static constexpr uintptr_t kRotationDegrees    = 0x4c8u; // float
        static constexpr uintptr_t kRotationSpd        = 0x4ccu; // float
        static constexpr uintptr_t kEndPoint           = 0x4d8u; // Vec2
        static constexpr uintptr_t kDisableFollowParent= 0x4e4u; // uint8
    }

    namespace Bomb {
        static constexpr uintptr_t kExplosionCountdown = 0x410u; // int32
        static constexpr uintptr_t kExplosionDamage    = 0x418u; // float
        static constexpr uintptr_t kFlags              = 0x438u; // uint64
        static constexpr uintptr_t kRadiusMultiplier   = 0x44cu; // float
    }

    namespace Effect {
        static constexpr uintptr_t kHeight    = 0x410u; // float
        static constexpr uintptr_t kState     = 0x450u; // int32
        static constexpr uintptr_t kMinRadius = 0x454u; // float
        static constexpr uintptr_t kMaxRadius = 0x458u; // float
        static constexpr uintptr_t kTimeout   = 0x45cu; // int32
        static constexpr uintptr_t kLifeSpan  = 0x460u; // int32
    }

    namespace Pickup {
        static constexpr uintptr_t kPrice = 0x534u; // int32
    }

    namespace Grid {
        static constexpr uintptr_t kType           = 0x4u;   // int32
        static constexpr uintptr_t kVariant        = 0x8u;   // int32
        static constexpr uintptr_t kState          = 0xcu;   // int32
        static constexpr uintptr_t kGridIdx        = 0x24u;  // int32
        static constexpr uintptr_t kCollisionClass = 0x3cu;  // int32
        static constexpr uintptr_t kSprite         = 0x40u;  // inline Sprite
        static constexpr uintptr_t kTimeoutOrCnt   = 0x154u; // int32
    }
}

namespace IsaacEnums {
    // EntityType IDs
    static constexpr int kEntPlayer     = 1;
    static constexpr int kEntBomb       = 4;
    static constexpr int kEntPickup     = 5;
    static constexpr int kEntLaser      = 7;
    static constexpr int kEntProjectile = 9;
    static constexpr int kEntMulligan   = 16;
    static constexpr int kEntBoomFly    = 25;
    static constexpr int kEntVis        = 39;
    static constexpr int kEntMonstro2   = 43;
    static constexpr int kEntMom        = 45;
    static constexpr int kEntGluttony   = 49;
    static constexpr int kEntLeech      = 55;
    static constexpr int kEntEye        = 60;
    static constexpr int kEntPin        = 62;
    static constexpr int kEntFallen     = 81;
    static constexpr int kEntSatan      = 84;
    static constexpr int kEntBlackMaw   = 225;
    static constexpr int kEntRageCreep  = 241;
    static constexpr int kEntTickingSpd = 250;
    static constexpr int kEntTheHaunt   = 260;
    static constexpr int kEntDarkOne    = 267;
    static constexpr int kEntUriel      = 271;
    static constexpr int kEntGabriel    = 272;
    static constexpr int kEntMegaSatan  = 274;
    static constexpr int kEntBlackBony  = 277;
    static constexpr int kEntRedGhost   = 285;
    static constexpr int kEntPoisonMind = 301;
    static constexpr int kEntFlyBomb    = 819;
    static constexpr int kEntPon        = 840;
    static constexpr int kEntGrudge     = 877;
    static constexpr int kEntMother     = 912;
    static constexpr int kEntDogma      = 950;
    static constexpr int kEntBeast      = 951;
    static constexpr int kEntEffect     = 1000;

    // GridCollisionClass IDs
    static constexpr int kGridCollNone       = 0;
    static constexpr int kGridCollPit        = 1;
    static constexpr int kGridCollObject     = 2;
    static constexpr int kGridCollSolid      = 3;
    static constexpr int kGridCollWall       = 4;
    static constexpr int kGridCollWallExcept = 5;

    // GridEntityType IDs
    static constexpr int kGridSpikes      = 8;
    static constexpr int kGridSpikesOnOff = 9;
    static constexpr int kGridLock        = 11;
    static constexpr int kGridPoop        = 14;

    // ProjectileFlags (uint64)
    static constexpr uint64_t kProjSmart            = 1ULL << 0;
    static constexpr uint64_t kProjExplode          = 1ULL << 1;
    static constexpr uint64_t kProjWiggle           = 1ULL << 5;
    static constexpr uint64_t kProjBoomerang        = 1ULL << 6;
    static constexpr uint64_t kProjOrbitCW          = 1ULL << 11;
    static constexpr uint64_t kProjOrbitCCW         = 1ULL << 12;
    static constexpr uint64_t kProjNoWallCollide    = 1ULL << 13;
    static constexpr uint64_t kProjAnyHeightHit     = 1ULL << 17;
    static constexpr uint64_t kProjCurveLeft        = 1ULL << 18;
    static constexpr uint64_t kProjCurveRight       = 1ULL << 19;
    static constexpr uint64_t kProjTurnHorizontal   = 1ULL << 20;
    static constexpr uint64_t kProjSineVelocity     = 1ULL << 21;
    static constexpr uint64_t kProjMegaWiggle       = 1ULL << 22;
    static constexpr uint64_t kProjSawtoothWiggle   = 1ULL << 23;
    static constexpr uint64_t kProjAccelerate       = 1ULL << 27;
    static constexpr uint64_t kProjDecelerate       = 1ULL << 28;
    static constexpr uint64_t kProjContinuum        = 1ULL << 30;
    static constexpr uint64_t kProjCantHitPlayer    = 1ULL << 31;
    static constexpr uint64_t kProjChangeFlags      = 1ULL << 32;
    static constexpr uint64_t kProjChangeVelocity   = 1ULL << 33;
    static constexpr uint64_t kProjAccelerateEx     = 1ULL << 37;
    static constexpr uint64_t kProjBounce           = 1ULL << 42;
    static constexpr uint64_t kProjBounceFloor      = 1ULL << 43;
    static constexpr uint64_t kProjSmartPerfect     = 1ULL << 48;

    // EntityFlags (uint64)
    static constexpr uint64_t kEntFlagDead         = 1ULL << 18;
    static constexpr uint64_t kEntFlagBossDeath    = 1ULL << 20;
    static constexpr uint64_t kEntFlagFriendly     = 1ULL << 29;
    static constexpr uint64_t kEntFlagCharmed      = 1ULL << 8;
    static constexpr uint64_t kEntFlagSlippery     = 1ULL << 27;
    static constexpr uint64_t kEntFlagNoQuery      = 1ULL << 46;
    static constexpr uint64_t kEntFlagIceFrozen    = 1ULL << 49;
}

// Abstract read-only memory accessor with cached page-readability verification.
struct MemReader {
    virtual ~MemReader() = default;
    virtual bool readable(uintptr_t addr, size_t bytes) const = 0;
    virtual bool readBytes(uintptr_t addr, void* out, size_t bytes) const = 0;

    template <typename T>
    bool read(uintptr_t addr, T& out) const {
        return readBytes(addr, &out, sizeof(T));
    }

    template <typename T>
    T readOr(uintptr_t addr, T fallback = T{}) const {
        T val{};
        return readBytes(addr, &val, sizeof(T)) ? val : fallback;
    }

    // Read a 32-bit target pointer (isaac-ng.exe is 32-bit x86).
    uintptr_t readPtr32(uintptr_t addr) const {
        uint32_t raw = 0;
        if (!read(addr, raw) || raw < 0x10000u) return 0;
        return static_cast<uintptr_t>(raw);
    }

    // Read MSVC 32-bit std::string (SSO cap < 16 inline vs heap buffer) at addr.
    bool readMsvcString(uintptr_t addr, char* buf, size_t bufCap) const {
        if (!addr || !buf || bufCap == 0) return false;
        buf[0] = '\0';
        uint32_t len = 0, cap = 0;
        if (!read(addr + 0x10u, len) || !read(addr + 0x14u, cap)) return false;
        if (len == 0 || cap == 0) return true;
        if (len > cap || len > 512u) return false;
        uintptr_t src = (cap >= 16u) ? readPtr32(addr) : addr;
        if (!src) return false;
        size_t n = std::min<size_t>(len, bufCap - 1);
        if (!readBytes(src, buf, n)) { buf[0] = '\0'; return false; }
        buf[n] = '\0';
        return true;
    }
};

#ifdef _WIN32
// In-process read-only memory reader with a tiny open-addressed page cache so
// every dereference is guarded against unmapped/freed pages without VirtualQuery overhead.
class LocalProcessReader final : public MemReader {
    static constexpr size_t kCacheSlots = 64;
    struct PageEntry {
        uintptr_t page = 0;
        uintptr_t end  = 0;
        bool ok        = false;
    };
    mutable PageEntry cache_[kCacheSlots]{};

    bool pageOk(uintptr_t pageAddr) const {
        if (pageAddr < 0x10000u || pageAddr > 0x7FFF0000u) return false;
        size_t slot = (pageAddr >> 12) & (kCacheSlots - 1);
        const PageEntry& e = cache_[slot];
        if (e.page != 0 && pageAddr >= e.page && pageAddr < e.end) return e.ok;
        MEMORY_BASIC_INFORMATION mbi{};
        bool ok = false;
        if (VirtualQuery(reinterpret_cast<LPCVOID>(pageAddr), &mbi, sizeof(mbi)) == sizeof(mbi)) {
            constexpr DWORD kReadMask = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                                        PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
            ok = (mbi.State == MEM_COMMIT) &&
                 ((mbi.Protect & PAGE_GUARD) == 0) &&
                 ((mbi.Protect & kReadMask) != 0);
            uintptr_t base = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
            uintptr_t end  = base + mbi.RegionSize;
            cache_[slot] = PageEntry{base, end, ok};
        } else {
            cache_[slot] = PageEntry{pageAddr, pageAddr + 0x1000u, false};
        }
        return ok;
    }

public:
    void resetCache() const {
        for (size_t i = 0; i < kCacheSlots; ++i) cache_[i] = PageEntry{};
    }

    bool readable(uintptr_t addr, size_t bytes) const override {
        if (addr < 0x10000u || bytes == 0 || bytes > 0x100000u) return false;
        uintptr_t last = addr + bytes - 1;
        if (last < addr || last > 0x7FFFFFFFu) return false;
        uintptr_t p = addr & ~uintptr_t(0xFFFu);
        uintptr_t pEnd = last & ~uintptr_t(0xFFFu);
        for (; p <= pEnd; p += 0x1000u) {
            if (!pageOk(p)) return false;
        }
        return true;
    }

    bool readBytes(uintptr_t addr, void* out, size_t bytes) const override {
        if (!readable(addr, bytes)) return false;
        std::memcpy(out, reinterpret_cast<const void*>(addr), bytes);
        return true;
    }
};
#endif

} // namespace iad
