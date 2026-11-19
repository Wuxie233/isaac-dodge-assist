#pragma once

#include "native_predict.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace iad {

// 9-direction protocol order: 0 idle, 1 L, 2 R, 3 U, 4 D, 5 LU, 6 RU, 7 LD, 8 RD
inline constexpr float kDiag = 0.7071067811865475f;
inline constexpr float kCandX[9] = {0.0f, -1.0f, 1.0f,  0.0f, 0.0f, -kDiag,  kDiag, -kDiag, kDiag};
inline constexpr float kCandY[9] = {0.0f,  0.0f, 0.0f, -1.0f, 1.0f, -kDiag, -kDiag,  kDiag, kDiag};
inline constexpr int kCandIntX[9] = {0, -1, 1, 0, 0, -1, 1, -1, 1};
inline constexpr int kCandIntY[9] = {0, 0, 0, -1, 1, -1, -1, 1, 1};

inline Vec2 candVec(int dir) {
    return (dir >= 0 && dir < 9) ? Vec2{kCandX[dir], kCandY[dir]} : Vec2{0.0f, 0.0f};
}

struct PlanResult {
    static constexpr double kScale = 1048576.0;
    static constexpr double kHard  = kScale * 1000000.0;

    bool valid = false;
    bool danger = false;
    bool inside = false;
    bool usedTurn = false;
    int blockedMask = 0;
    int bestDir = -1;
    double straightScores[9]{};
    double scores[9]{};
};

namespace planner_detail {

// Calibrated 60Hz player kinematics (verified against 0x6aec04 & player_motion.lua).
// Entity_Player updates twice per 30Hz frame; Entity::kVel is already px per 60Hz tick!
struct PlayerKinematics {
    float fDrive = 0.874f;
    float fIdle  = 0.880f;
    float accel  = 0.5292f;
    int extraDelay60 = 0;
    Vec2 extAccel{0.0f, 0.0f};

    static PlayerKinematics fast(const PlayerState& pl, Vec2 ext = {0.0f, 0.0f}) {
        PlayerKinematics k{};
        k.fDrive = pl.slippery ? 0.980f : 0.874f;
        k.fIdle  = pl.slippery ? 0.980f : 0.880f;
        k.accel  = 4.2f * pl.moveSpeed * (1.0f - k.fDrive);
        k.extraDelay60 = 0;
        k.extAccel = ext;
        return k;
    }

    static PlayerKinematics slow(const PlayerState& pl, Vec2 ext = {0.0f, 0.0f}) {
        PlayerKinematics k{};
        k.fDrive = pl.slippery ? 0.987f : 0.894f;
        k.fIdle  = pl.slippery ? 0.987f : 0.895f;
        k.accel  = (4.2f * 0.97f) * pl.moveSpeed * (1.0f - k.fDrive);
        k.extraDelay60 = 2;
        k.extAccel = ext;
        return k;
    }
};

inline float clamp01(float v) {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

inline float pointSegmentDistSq(float px, float py, float ax, float ay, float bx, float by) {
    float dx = bx - ax, dy = by - ay;
    float vx = px - ax, vy = py - ay;
    float lenSq = dx * dx + dy * dy;
    float u = (lenSq > 1e-6f) ? clamp01((vx * dx + vy * dy) / lenSq) : 0.0f;
    float rx = vx - dx * u, ry = vy - dy * u;
    return rx * rx + ry * ry;
}

inline float segmentSegmentDistSqPre(float ax, float ay, float bx, float by,
                                     float cx, float cy, float cdx, float cdy,
                                     float cdLenSq, float cdInvLenSq) {
    float abx = bx - ax, aby = by - ay;
    float denom = abx * cdy - aby * cdx;
    if (std::abs(denom) > 1e-6f) {
        float x = cx - ax, y = cy - ay;
        float numT = x * cdy - y * cdx;
        float numU = x * aby - y * abx;
        if (denom > 0.0f) {
            if (numT >= 0.0f && numT <= denom && numU >= 0.0f && numU <= denom) return 0.0f;
        } else {
            if (numT <= 0.0f && numT >= denom && numU <= 0.0f && numU >= denom) return 0.0f;
        }
    }
    float d1, d2;
    if (cdLenSq > 1e-6f) {
        float acx = ax - cx, acy = ay - cy;
        float bcx = bx - cx, bcy = by - cy;
        float u1 = (acx * cdx + acy * cdy) * cdInvLenSq;
        float u2 = (bcx * cdx + bcy * cdy) * cdInvLenSq;
        float uc1 = clamp01(u1), uc2 = clamp01(u2);
        float rx1 = acx - cdx * uc1, ry1 = acy - cdy * uc1;
        float rx2 = bcx - cdx * uc2, ry2 = bcy - cdy * uc2;
        d1 = rx1 * rx1 + ry1 * ry1;
        d2 = rx2 * rx2 + ry2 * ry2;
        if (u1 >= 0.0f && u1 <= 1.0f && u2 >= 0.0f && u2 <= 1.0f) {
            return std::min(d1, d2);
        }
    } else {
        float acx = ax - cx, acy = ay - cy;
        float bcx = bx - cx, bcy = by - cy;
        d1 = acx * acx + acy * acy;
        d2 = bcx * bcx + bcy * bcy;
    }
    float abLenSq = abx * abx + aby * aby;
    float d3, d4;
    if (abLenSq > 1e-6f) {
        float invAb = 1.0f / abLenSq;
        float cax = cx - ax, cay = cy - ay;
        float dax = (cx + cdx) - ax, day = (cy + cdy) - ay;
        float v1 = clamp01((cax * abx + cay * aby) * invAb);
        float v2 = clamp01((dax * abx + day * aby) * invAb);
        float rx3 = cax - abx * v1, ry3 = cay - aby * v1;
        float rx4 = dax - abx * v2, ry4 = day - aby * v2;
        d3 = rx3 * rx3 + ry3 * ry3;
        d4 = rx4 * rx4 + ry4 * ry4;
    } else {
        float cax = cx - ax, cay = cy - ay;
        float dax = (cx + cdx) - ax, day = (cy + cdy) - ay;
        d3 = cax * cax + cay * cay;
        d4 = dax * dax + day * day;
    }
    return std::min(std::min(d1, d2), std::min(d3, d4));
}

inline float segmentSegmentDistSq(float ax, float ay, float bx, float by,
                                  float cx, float cy, float dx, float dy) {
    float cdx = dx - cx, cdy = dy - cy;
    float cdLenSq = cdx * cdx + cdy * cdy;
    float cdInv = (cdLenSq > 1e-6f) ? (1.0f / cdLenSq) : 0.0f;
    return segmentSegmentDistSqPre(ax, ay, bx, by, cx, cy, cdx, cdy, cdLenSq, cdInv);
}

// Minimum swept penetration against a segment relative motion:
// body A moves p0->p1 while body B moves q0->q1. Return positive overlap depth or negative gap (clamped <= -24).
inline float sweptRelativeClearance(Vec2 p0, Vec2 p1, Vec2 q0, Vec2 q1, float radiusSum, float gapMargin = 24.0f) {
    float bound = radiusSum + gapMargin;
    if (std::max(p0.x, p1.x) + bound < std::min(q0.x, q1.x) ||
        std::min(p0.x, p1.x) - bound > std::max(q0.x, q1.x) ||
        std::max(p0.y, p1.y) + bound < std::min(q0.y, q1.y) ||
        std::min(p0.y, p1.y) - bound > std::max(q0.y, q1.y)) {
        return -24.0f;
    }
    float rx0 = p0.x - q0.x, ry0 = p0.y - q0.y;
    float rvx = (p1.x - p0.x) - (q1.x - q0.x);
    float rvy = (p1.y - p0.y) - (q1.y - q0.y);
    float lenSq = rvx * rvx + rvy * rvy;
    float u = (lenSq > 1e-6f) ? clamp01(-(rx0 * rvx + ry0 * rvy) / lenSq) : 0.0f;
    float cx = rx0 + rvx * u, cy = ry0 + rvy * u;
    float distSq = cx * cx + cy * cy;
    if (distSq >= bound * bound) return -24.0f;
    return radiusSum - std::sqrt(distSq);
}

// Faster variant using precomputed step AABB of p0->p1. Returns positive pen (or 1.0f if abortCheck && hit).
inline float sweptRelativeClearanceFast(Vec2 p0, Vec2 p1, float pMinX, float pMaxX, float pMinY, float pMaxY,
                                        Vec2 q0, Vec2 q1, float radiusSum, float gapMargin,
                                        bool skipSqrtOnHardHit) {
    float bound = radiusSum + gapMargin;
    if (pMaxX + bound < std::min(q0.x, q1.x) || pMinX - bound > std::max(q0.x, q1.x) ||
        pMaxY + bound < std::min(q0.y, q1.y) || pMinY - bound > std::max(q0.y, q1.y)) {
        return -24.0f;
    }
    float rx0 = p0.x - q0.x, ry0 = p0.y - q0.y;
    float rvx = (p1.x - p0.x) - (q1.x - q0.x);
    float rvy = (p1.y - p0.y) - (q1.y - q0.y);
    float lenSq = rvx * rvx + rvy * rvy;
    float u = (lenSq > 1e-6f) ? clamp01(-(rx0 * rvx + ry0 * rvy) / lenSq) : 0.0f;
    float cx = rx0 + rvx * u, cy = ry0 + rvy * u;
    float distSq = cx * cx + cy * cy;
    if (distSq >= bound * bound) return -24.0f;
    if (skipSqrtOnHardHit && distSq < radiusSum * radiusSum) return 1.0f;
    return radiusSum - std::sqrt(distSq);
}

// Swept penetration of moving player [p0, p1] against a capsule segment [c0, c1] (e.g. chain-pushed bomb blast).
inline float sweptCapsuleClearance(Vec2 p0, Vec2 p1, Vec2 c0, Vec2 c1, float radiusSum, float gapMargin = 24.0f) {
    float bound = radiusSum + gapMargin;
    if (std::max(p0.x, p1.x) + bound < std::min(c0.x, c1.x) ||
        std::min(p0.x, p1.x) - bound > std::max(c0.x, c1.x) ||
        std::max(p0.y, p1.y) + bound < std::min(c0.y, c1.y) ||
        std::min(p0.y, p1.y) - bound > std::max(c0.y, c1.y)) {
        return -24.0f;
    }
    float distSq = segmentSegmentDistSq(p0.x, p0.y, p1.x, p1.y, c0.x, c0.y, c1.x, c1.y);
    if (distSq >= bound * bound) return -24.0f;
    return radiusSum - std::sqrt(distSq);
}

struct ChunkBox {
    float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
    void reset() { minX = 1e9f; maxX = -1e9f; minY = 1e9f; maxY = -1e9f; }
    void expand(float x, float y) {
        minX = std::min(minX, x); maxX = std::max(maxX, x);
        minY = std::min(minY, y); maxY = std::max(maxY, y);
    }
    void expandBox(float x0, float x1, float y0, float y1) {
        minX = std::min(minX, x0); maxX = std::max(maxX, x1);
        minY = std::min(minY, y0); maxY = std::max(maxY, y1);
    }
};

struct PrecompLaserStep {
    float t0, t1;
    Vec2 orig0, orig1;
    float cosA, sinA, rotMargin;
    Vec2 segA, segB; // pre-rotated segment when twoPts == true
    float segDx, segDy, segLenSq, segInvLenSq;
    float sMinX, sMaxX, sMinY, sMaxY;
    int rotCacheOffset; // lazy offset into PrecompThreats::rotPtsCache for rotating multi-pt lasers
    bool twoPts;
    bool midZero;
    bool active;
};

struct PrecompLaser {
    float minX, maxX, minY, maxY;
    int firstActiveK;
    int lastActiveK;
    int stepOffset;
    ChunkBox chunks[8];
};

struct ActiveBullet {
    int idx;
    int lo;
    int hi;
    float minX, maxX, minY, maxY;
    float radius;
    uint8_t warning;
};

struct StaticDisc {
    Vec2 pos;
    float radius;
    int lo;
    int hi;
    uint8_t warning;
    uint8_t groundOnly;
};

struct MovingDisc {
    int lo;
    int hi;
    int ptsOffset;
    float minX, maxX, minY, maxY;
    float radius;
    Vec2 sweepEndOffset;
    uint8_t warning;
    uint8_t groundOnly;
    uint8_t isCapsule;
    ChunkBox chunks[8];
};

struct PrecompThreats {
    static constexpr int kInlineBullets = 64;
    static constexpr int kInlineDiscs = 32;
    static constexpr int kInlineMovingDiscs = 16;
    static constexpr int kInlineLasers = 8;
    static constexpr int kInlineDiscPts = 16 * 64; // pairs (c0, c1) -> *2
    static constexpr int kInlineLaserSteps = 8 * BulletTrack::kMaxPts;

    int maxK = 0;
    int numChunks = 1;
    int minHardK = 10000;
    int maxHardK = -1;
    bool gridHasAutoAvoid = false;

    int numBullets = 0;
    ActiveBullet inlineBullets[kInlineBullets];
    std::vector<ActiveBullet> extraBullets;
    ChunkBox inlineBulletChunks[kInlineBullets * 8];
    std::vector<ChunkBox> extraBulletChunks;
    const ActiveBullet* bulletsPtr = nullptr;
    const ChunkBox* bulletChunksPtr = nullptr;

    int numStaticDiscs = 0;
    StaticDisc inlineStaticDiscs[kInlineDiscs];
    std::vector<StaticDisc> extraStaticDiscs;
    const StaticDisc* staticDiscsPtr = nullptr;

    int numMovingDiscs = 0;
    MovingDisc inlineMovingDiscs[kInlineMovingDiscs];
    std::vector<MovingDisc> extraMovingDiscs;
    const MovingDisc* movingDiscsPtr = nullptr;
    Vec2 inlineDiscPts[kInlineDiscPts * 2];
    std::vector<Vec2> extraDiscPts;
    const Vec2* discPtsPtr = nullptr;

    int numLasers = 0;
    PrecompLaser inlineLasers[kInlineLasers];
    std::vector<PrecompLaser> extraLasers;
    PrecompLaser* lasersPtr = nullptr;
    PrecompLaserStep inlineLaserSteps[kInlineLaserSteps];
    std::vector<PrecompLaserStep> extraLaserSteps;
    PrecompLaserStep* laserStepsPtr = nullptr;
    mutable std::vector<Vec2> rotPtsCache; // lazy rotated polyline points for rotating multi-pt lasers

    void init(const ThreatScene& scene, int maxKIn, bool allowPickups, bool hasAutoAvoid) {
        maxK = maxKIn;
        numChunks = (maxK >> 3) + 1;
        minHardK = maxK + 1;
        maxHardK = -1;
        gridHasAutoAvoid = (!allowPickups) && hasAutoAvoid;
        float ep = scene.entityPhase;

        // 1. Bullets + 8-step chunk AABBs
        int rawB = static_cast<int>(scene.bullets.size());
        ActiveBullet* bDst = inlineBullets;
        ChunkBox* cDst = inlineBulletChunks;
        if (rawB > kInlineBullets) {
            extraBullets.resize(rawB);
            extraBulletChunks.resize(static_cast<size_t>(rawB) * static_cast<size_t>(numChunks));
            bDst = extraBullets.data();
            cDst = extraBulletChunks.data();
        }
        int activeB = 0;
        for (int i = 0; i < rawB; ++i) {
            const BulletTrack& b = scene.bullets[i];
            int lo = std::max(0, b.firstStep);
            int hi = std::min(maxK, b.lastStep);
            if (lo > hi) continue;
            ActiveBullet& ab = bDst[activeB++];
            ab.idx = i;
            ab.lo = lo;
            ab.hi = hi;
            ab.minX = b.minX; ab.maxX = b.maxX;
            ab.minY = b.minY; ab.maxY = b.maxY;
            ab.radius = b.radius;
            ab.warning = b.warning;
            if (!b.warning) {
                minHardK = std::min(minHardK, lo);
                maxHardK = std::max(maxHardK, hi);
            }
        }
        numBullets = activeB;
        bulletsPtr = bDst;
        bulletChunksPtr = cDst;
        for (int blk = 0; blk < numChunks; ++blk) {
            int kA = blk * 8;
            int kB = std::min(maxK, kA + 7);
            ChunkBox* row = cDst + blk * numBullets;
            for (int bi = 0; bi < numBullets; ++bi) {
                const ActiveBullet& ab = bDst[bi];
                const BulletTrack& b = scene.bullets[ab.idx];
                int lo = std::max(kA, ab.lo);
                int hi = std::min(kB, ab.hi);
                ChunkBox& box = row[bi];
                box.reset();
                if (lo <= hi) {
                    Vec2 q0 = (lo == 0) ? b.pts[0] : b.pts[lo - 1];
                    box.expand(q0.x, q0.y);
                    for (int k = lo; k <= hi; ++k) {
                        box.expand(b.pts[k].x, b.pts[k].y);
                    }
                }
            }
        }

        // 2. Discs: split into static non-capsule vs moving/capsule with exact pre-trimmed [lo..hi]
        bool allFly = scene.player.canFly && (!scene.hasTwin || scene.twin.canFly);
        int rawD = static_cast<int>(scene.discs.size());
        numStaticDiscs = 0;
        numMovingDiscs = 0;
        extraStaticDiscs.clear();
        extraMovingDiscs.clear();
        int discPtsCount = 0;
        bool usingExtraDiscPts = false;
        int strideD = (maxK + 1) * 2;
        for (int i = 0; i < rawD; ++i) {
            const DiscHazard& d = scene.discs[i];
            if (d.groundOnly && allFly) continue;
            if (d.autoOnly && allowPickups) continue;

            int lo = 0;
            if (d.fromT > ep) {
                lo = std::max(lo, static_cast<int>(std::ceil((d.fromT - ep) * 2.0f - 1e-4f)));
            }
            int hi = maxK;
            if (d.toT < 1e5f) {
                hi = std::min(hi, static_cast<int>(std::floor((d.toT - ep) * 2.0f + 1.0f + 1e-4f)));
            }
            while (lo <= hi && (static_cast<float>(lo) * 0.5f + ep) < d.fromT) ++lo;
            while (lo <= hi && (((hi == 0) ? 0.0f : static_cast<float>(hi - 1) * 0.5f) + ep) > d.toT) --hi;
            if (lo > hi) continue;
            if (!d.warning) {
                minHardK = std::min(minHardK, lo);
                maxHardK = std::max(maxHardK, hi);
            }

            if (!d.isCapsule && d.vel.x == 0.0f && d.vel.y == 0.0f) {
                StaticDisc sd{d.pos, d.radius, lo, hi, d.warning, static_cast<uint8_t>(d.groundOnly ? 1 : 0)};
                if (extraStaticDiscs.empty() && numStaticDiscs < kInlineDiscs) {
                    inlineStaticDiscs[numStaticDiscs++] = sd;
                } else {
                    if (extraStaticDiscs.empty()) {
                        extraStaticDiscs.assign(inlineStaticDiscs, inlineStaticDiscs + numStaticDiscs);
                    }
                    extraStaticDiscs.push_back(sd);
                    ++numStaticDiscs;
                }
            } else {
                MovingDisc* mdPtr = nullptr;
                if (extraMovingDiscs.empty() && numMovingDiscs < kInlineMovingDiscs) {
                    mdPtr = &inlineMovingDiscs[numMovingDiscs++];
                } else {
                    if (extraMovingDiscs.empty()) {
                        extraMovingDiscs.resize(numMovingDiscs + 1);
                        for (int m = 0; m < numMovingDiscs; ++m) extraMovingDiscs[m] = inlineMovingDiscs[m];
                    } else {
                        extraMovingDiscs.emplace_back();
                    }
                    mdPtr = &extraMovingDiscs.back();
                    ++numMovingDiscs;
                }
                MovingDisc& md = *mdPtr;
                md.lo = lo;
                md.hi = hi;
                md.ptsOffset = discPtsCount;
                md.radius = d.radius;
                md.sweepEndOffset = d.sweepEndOffset;
                md.warning = d.warning;
                md.groundOnly = d.groundOnly ? 1 : 0;
                md.isCapsule = d.isCapsule ? 1 : 0;
                for (int blk = 0; blk < numChunks; ++blk) md.chunks[blk].reset();

                if (!usingExtraDiscPts && discPtsCount + strideD > kInlineDiscPts * 2) {
                    extraDiscPts.assign(inlineDiscPts, inlineDiscPts + discPtsCount);
                    usingExtraDiscPts = true;
                }
                Vec2* ptsOut = nullptr;
                if (!usingExtraDiscPts) {
                    ptsOut = inlineDiscPts + discPtsCount;
                } else {
                    extraDiscPts.resize(discPtsCount + strideD);
                    ptsOut = extraDiscPts.data() + discPtsCount;
                }
                discPtsCount += strideD;

                ChunkBox gbox;
                gbox.reset();
                for (int k = lo; k <= hi; ++k) {
                    float t0 = ((k == 0) ? 0.0f : static_cast<float>(k - 1) * 0.5f) + ep;
                    float t1 = static_cast<float>(k) * 0.5f + ep;
                    Vec2 q0 = d.pos + d.vel * t0;
                    Vec2 q1 = d.isCapsule ? (d.pos + d.vel * t1 + d.sweepEndOffset) : (d.pos + d.vel * t1);
                    ptsOut[k * 2] = q0;
                    ptsOut[k * 2 + 1] = q1;
                    gbox.expand(q0.x, q0.y);
                    gbox.expand(q1.x, q1.y);
                    int blk = k >> 3;
                    md.chunks[blk].expand(q0.x, q0.y);
                    md.chunks[blk].expand(q1.x, q1.y);
                }
                md.minX = gbox.minX; md.maxX = gbox.maxX;
                md.minY = gbox.minY; md.maxY = gbox.maxY;
            }
        }
        staticDiscsPtr = extraStaticDiscs.empty() ? inlineStaticDiscs : extraStaticDiscs.data();
        movingDiscsPtr = extraMovingDiscs.empty() ? inlineMovingDiscs : extraMovingDiscs.data();
        discPtsPtr = usingExtraDiscPts ? extraDiscPts.data() : inlineDiscPts;

        // 3. Lasers: precompute geometry, step bounds, and 8-step chunks with trig recurrence
        numLasers = static_cast<int>(scene.lasers.size());
        int stepStride = maxK + 1;
        if (numLasers <= kInlineLasers) {
            lasersPtr = inlineLasers;
            laserStepsPtr = inlineLaserSteps;
        } else {
            extraLasers.resize(numLasers);
            extraLaserSteps.resize(static_cast<size_t>(numLasers) * static_cast<size_t>(stepStride));
            lasersPtr = extraLasers.data();
            laserStepsPtr = extraLaserSteps.data();
        }
        float maxT = static_cast<float>(maxK) * 0.5f + ep;
        for (int i = 0; i < numLasers; ++i) {
            const LaserHazard& l = scene.lasers[i];
            PrecompLaser& p = lasersPtr[i];
            p.stepOffset = i * stepStride;
            PrecompLaserStep* stepsArr = laserStepsPtr + p.stepOffset;
            float pad = l.width + 2.0f;
            float vx0 = std::min(0.0f, l.vel.x * maxT);
            float vx1 = std::max(0.0f, l.vel.x * maxT);
            float vy0 = std::min(0.0f, l.vel.y * maxT);
            float vy1 = std::max(0.0f, l.vel.y * maxT);
            float unrotMinX = 0.0f, unrotMaxX = 0.0f, unrotMinY = 0.0f, unrotMaxY = 0.0f;
            if (l.ring) {
                float ext = l.radius + pad;
                p.minX = l.origin.x + vx0 - ext; p.maxX = l.origin.x + vx1 + ext;
                p.minY = l.origin.y + vy0 - ext; p.maxY = l.origin.y + vy1 + ext;
            } else {
                if (l.numPts > 0) {
                    unrotMinX = unrotMaxX = l.pts[0].x;
                    unrotMinY = unrotMaxY = l.pts[0].y;
                    for (int j = 1; j < l.numPts; ++j) {
                        unrotMinX = std::min(unrotMinX, l.pts[j].x);
                        unrotMaxX = std::max(unrotMaxX, l.pts[j].x);
                        unrotMinY = std::min(unrotMinY, l.pts[j].y);
                        unrotMaxY = std::max(unrotMaxY, l.pts[j].y);
                    }
                }
                if (l.angularSpeed != 0.0f || l.numPts <= 0) {
                    float ext = l.reach + pad;
                    p.minX = l.origin.x + vx0 - ext; p.maxX = l.origin.x + vx1 + ext;
                    p.minY = l.origin.y + vy0 - ext; p.maxY = l.origin.y + vy1 + ext;
                } else {
                    p.minX = l.origin.x + vx0 + unrotMinX - pad; p.maxX = l.origin.x + vx1 + unrotMaxX + pad;
                    p.minY = l.origin.y + vy0 + unrotMinY - pad; p.maxY = l.origin.y + vy1 + unrotMaxY + pad;
                }
            }
            for (int blk = 0; blk < numChunks; ++blk) p.chunks[blk].reset();
            p.firstActiveK = 10000;
            p.lastActiveK = -1;
            bool isTwo = (!l.ring && l.numPts == 2);
            Vec2 unrotSegA = isTwo ? l.pts[0] : Vec2{};
            Vec2 unrotSegB = isTwo ? l.pts[1] : Vec2{};
            float unrotDx = unrotSegB.x - unrotSegA.x;
            float unrotDy = unrotSegB.y - unrotSegA.y;
            float unrotLenSq = unrotDx * unrotDx + unrotDy * unrotDy;
            float unrotInvLenSq = (unrotLenSq > 1e-6f) ? (1.0f / unrotLenSq) : 0.0f;

            bool hasRotRec = false;
            double recC = 1.0, recS = 0.0, dRotC = 1.0, dRotS = 0.0;
            if (!l.ring && l.angularSpeed != 0.0f) {
                double dRad = static_cast<double>(l.angularSpeed) * 0.5 * 0.017453292519943295;
                dRotC = std::cos(dRad);
                dRotS = std::sin(dRad);
            }

            for (int k = 0; k <= maxK; ++k) {
                PrecompLaserStep& st = stepsArr[k];
                st.t0 = ((k == 0) ? 0.0f : static_cast<float>(k - 1) * 0.5f) + ep;
                st.t1 = static_cast<float>(k) * 0.5f + ep;
                st.active = !(st.t1 < l.activeFrom || st.t0 > l.timeoutT) && (l.ring || l.numPts >= 2);
                st.twoPts = isTwo;
                st.rotCacheOffset = -1;
                if (!st.active) continue;
                p.firstActiveK = std::min(p.firstActiveK, k);
                p.lastActiveK = std::max(p.lastActiveK, k);
                st.orig0 = {l.origin.x + l.vel.x * st.t0, l.origin.y + l.vel.y * st.t0};
                st.orig1 = {l.origin.x + l.vel.x * st.t1, l.origin.y + l.vel.y * st.t1};
                int blk = k >> 3;
                if (l.ring) {
                    float ext = l.radius + l.width + 1.0f;
                    p.chunks[blk].expandBox(std::min(st.orig0.x, st.orig1.x) - ext,
                                            std::max(st.orig0.x, st.orig1.x) + ext,
                                            std::min(st.orig0.y, st.orig1.y) - ext,
                                            std::max(st.orig0.y, st.orig1.y) + ext);
                    continue;
                }
                if (l.angularSpeed == 0.0f || st.t1 <= l.rotDelay) {
                    st.midZero = true;
                    st.cosA = 1.0f; st.sinA = 0.0f; st.rotMargin = 0.0f;
                    if (isTwo) {
                        st.segA = unrotSegA; st.segB = unrotSegB;
                        st.segDx = unrotDx; st.segDy = unrotDy;
                        st.segLenSq = unrotLenSq; st.segInvLenSq = unrotInvLenSq;
                    }
                    st.sMinX = unrotMinX; st.sMaxX = unrotMaxX;
                    st.sMinY = unrotMinY; st.sMaxY = unrotMaxY;
                } else {
                    float ang0 = l.angularSpeed * std::max(0.0f, st.t0 - l.rotDelay);
                    float ang1 = l.angularSpeed * std::max(0.0f, st.t1 - l.rotDelay);
                    float midAng = 0.5f * (ang0 + ang1);
                    st.midZero = std::abs(midAng) < 1e-4f;
                    if (!st.midZero) {
                        if (hasRotRec && k >= 2 && (st.t0 - 0.5f) >= l.rotDelay) {
                            double nc = recC * dRotC - recS * dRotS;
                            double ns = recS * dRotC + recC * dRotS;
                            recC = nc; recS = ns;
                        } else {
                            double rad = static_cast<double>(midAng) * 0.017453292519943295;
                            recC = std::cos(rad);
                            recS = std::sin(rad);
                            hasRotRec = (k >= 1 && st.t0 >= l.rotDelay);
                        }
                        st.cosA = static_cast<float>(recC);
                        st.sinA = static_cast<float>(recS);
                    } else {
                        st.cosA = 1.0f;
                        st.sinA = 0.0f;
                    }
                    st.rotMargin = l.reach * std::abs(ang1 - ang0) * 0.0174532925f * 0.5f;
                    if (isTwo) {
                        st.segA = {l.pts[0].x * st.cosA - l.pts[0].y * st.sinA,
                                   l.pts[0].x * st.sinA + l.pts[0].y * st.cosA};
                        st.segB = {l.pts[1].x * st.cosA - l.pts[1].y * st.sinA,
                                   l.pts[1].x * st.sinA + l.pts[1].y * st.cosA};
                        st.segDx = st.segB.x - st.segA.x;
                        st.segDy = st.segB.y - st.segA.y;
                        st.segLenSq = st.segDx * st.segDx + st.segDy * st.segDy;
                        st.segInvLenSq = (st.segLenSq > 1e-6f) ? (1.0f / st.segLenSq) : 0.0f;
                        st.sMinX = std::min(st.segA.x, st.segB.x); st.sMaxX = std::max(st.segA.x, st.segB.x);
                        st.sMinY = std::min(st.segA.y, st.segB.y); st.sMaxY = std::max(st.segA.y, st.segB.y);
                    } else {
                        float ext = l.reach;
                        st.sMinX = -ext; st.sMaxX = ext;
                        st.sMinY = -ext; st.sMaxY = ext;
                    }
                }
                float stepPad = l.width + st.rotMargin + 1.0f;
                p.chunks[blk].expandBox(std::min(st.orig0.x, st.orig1.x) + st.sMinX - stepPad,
                                        std::max(st.orig0.x, st.orig1.x) + st.sMaxX + stepPad,
                                        std::min(st.orig0.y, st.orig1.y) + st.sMinY - stepPad,
                                        std::max(st.orig0.y, st.orig1.y) + st.sMaxY + stepPad);
            }
            if (!l.warning && p.firstActiveK <= p.lastActiveK) {
                minHardK = std::min(minHardK, p.firstActiveK);
                maxHardK = std::max(maxHardK, p.lastActiveK);
            }
        }
    }

    const Vec2* getLaserRotPts(const LaserHazard& l, PrecompLaserStep& ps) const {
        if (ps.rotCacheOffset >= 0) {
            return rotPtsCache.data() + ps.rotCacheOffset;
        }
        int offset = static_cast<int>(rotPtsCache.size());
        rotPtsCache.resize(offset + l.numPts);
        Vec2* dst = rotPtsCache.data() + offset;
        float c = ps.cosA, s = ps.sinA;
        float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
        for (int i = 0; i < l.numPts; ++i) {
            Vec2 rp{l.pts[i].x * c - l.pts[i].y * s, l.pts[i].x * s + l.pts[i].y * c};
            dst[i] = rp;
            minX = std::min(minX, rp.x); maxX = std::max(maxX, rp.x);
            minY = std::min(minY, rp.y); maxY = std::max(maxY, rp.y);
        }
        ps.sMinX = minX; ps.sMaxX = maxX;
        ps.sMinY = minY; ps.sMaxY = maxY;
        ps.rotCacheOffset = offset;
        return dst;
    }
};

inline float laserClearanceAtStepPre(const LaserHazard& l, PrecompLaserStep& ps,
                                     const PrecompThreats* pt,
                                     Vec2 p0, Vec2 p1, float playerRadius, float gapMargin = 24.0f) {
    if (!ps.active) return -1e6f;
    float radSum = playerRadius + l.width;
    Vec2 a{p0.x - ps.orig0.x, p0.y - ps.orig0.y};
    Vec2 b{p1.x - ps.orig1.x, p1.y - ps.orig1.y};

    if (l.ring) {
        float pad = radSum + gapMargin;
        float nearSq = pointSegmentDistSq(0.0f, 0.0f, a.x, a.y, b.x, b.y);
        float maxOuter = l.radius + pad;
        if (nearSq > maxOuter * maxOuter) return -24.0f;
        float farSq = std::max(a.lengthSq(), b.lengthSq());
        float minInner = l.radius - pad;
        if (minInner > 0.0f && farSq < minInner * minInner) return -24.0f;
        float nearD = std::sqrt(nearSq);
        float farD = std::sqrt(farSq);
        float shellGap = std::max({nearD - l.radius, l.radius - farD, 0.0f});
        return radSum - shellGap;
    }

    float effRad = radSum + ps.rotMargin;
    float pad = effRad + gapMargin;

    if (ps.twoPts) {
        if (std::max(a.x, b.x) + pad < ps.sMinX || std::min(a.x, b.x) - pad > ps.sMaxX ||
            std::max(a.y, b.y) + pad < ps.sMinY || std::min(a.y, b.y) - pad > ps.sMaxY) {
            return -24.0f;
        }
        float d2 = segmentSegmentDistSqPre(a.x, a.y, b.x, b.y,
                                           ps.segA.x, ps.segA.y, ps.segDx, ps.segDy,
                                           ps.segLenSq, ps.segInvLenSq);
        if (d2 >= pad * pad) return -24.0f;
        return effRad - std::sqrt(d2);
    }

    const Vec2* pts = ps.midZero ? l.pts : pt->getLaserRotPts(l, ps);
    float aMinX = std::min(a.x, b.x) - pad, aMaxX = std::max(a.x, b.x) + pad;
    float aMinY = std::min(a.y, b.y) - pad, aMaxY = std::max(a.y, b.y) + pad;
    if (aMaxX < ps.sMinX || aMinX > ps.sMaxX || aMaxY < ps.sMinY || aMinY > ps.sMaxY) {
        return -24.0f;
    }
    float padSq = pad * pad;
    float minDistSq = 1e12f;
    for (int i = 1; i < l.numPts; ++i) {
        const Vec2& pA = pts[i - 1];
        const Vec2& pB = pts[i];
        if (std::max(pA.x, pB.x) < aMinX || std::min(pA.x, pB.x) > aMaxX ||
            std::max(pA.y, pB.y) < aMinY || std::min(pA.y, pB.y) > aMaxY) {
            continue;
        }
        float d2 = segmentSegmentDistSq(a.x, a.y, b.x, b.y, pA.x, pA.y, pB.x, pB.y);
        if (d2 < minDistSq) {
            minDistSq = d2;
            if (minDistSq == 0.0f) break;
        }
    }
    if (minDistSq >= padSq) return -24.0f;
    return effRad - std::sqrt(minDistSq);
}

struct RolloutSnapshot {
    Vec2 pos;
    Vec2 vel;
    Vec2 twinPos;
    Vec2 twinVel;
    bool moved = false;
    bool hasHard = false;
    bool hasWarn = false;
    bool crossedAutoAvoid = false;
    int firstHardK = 10000;
    int lastHardK = -1;
    int hardHitSteps = 0;
    float maxHardPen = 0.0f;
    float endHardPen = 0.0f;
    float hardExposure = 0.0f;
    float maxWarnPen = 0.0f;
    float warnWeighted = 0.0f;
    float minClearance = 24.0f;
    float endClearance = 24.0f;
};

struct RolloutState {
    Vec2 pos;
    Vec2 vel;
    Vec2 twinPos;
    Vec2 twinVel;
    bool moved = false;
    bool hasHard = false;
    bool hasWarn = false;
    bool crossedAutoAvoid = false;
    int firstHardK = 10000;
    int lastHardK = -1;
    int hardHitSteps = 0;
    float maxHardPen = 0.0f;
    float endHardPen = 0.0f;
    float hardExposure = 0.0f;
    float maxWarnPen = 0.0f;
    float warnWeighted = 0.0f;
    float minClearance = 24.0f;
    float endClearance = 24.0f;
    RolloutSnapshot snaps[3]{};

    void initFromSnap(const RolloutSnapshot& sn) {
        pos = sn.pos; vel = sn.vel;
        twinPos = sn.twinPos; twinVel = sn.twinVel;
        moved = sn.moved;
        hasHard = sn.hasHard;
        hasWarn = sn.hasWarn;
        crossedAutoAvoid = sn.crossedAutoAvoid;
        firstHardK = sn.firstHardK;
        lastHardK = sn.lastHardK;
        hardHitSteps = sn.hardHitSteps;
        maxHardPen = sn.maxHardPen;
        endHardPen = sn.endHardPen;
        hardExposure = sn.hardExposure;
        maxWarnPen = sn.maxWarnPen;
        warnWeighted = sn.warnWeighted;
        minClearance = sn.minClearance;
        endClearance = sn.endClearance;
    }
};

struct TurnPathBuffer {
    Vec2 path[BulletTrack::kMaxPts]{};
    Vec2 twinPath[BulletTrack::kMaxPts]{};
};

// Physical intrusion penalty only (walls, L-room cutouts, solid rocks/pits).
// Uses RoomGrid::lRoomCutoutOverflow & cellPhysicallyPassable as single source of truth.
inline float footprintPenalty(const RoomGrid& grid, float x, float y, float radius, bool canFly) {
    auto boundsOverflow = [&](float px, float py) -> float {
        float over = 0.0f;
        if (!grid.beast) {
            if (px < grid.topLeft.x) over += (grid.topLeft.x - px);
            if (px > grid.bottomRight.x) over += (px - grid.bottomRight.x);
            if (py < grid.topLeft.y) over += (grid.topLeft.y - py);
            if (py > grid.bottomRight.y) over += (py - grid.bottomRight.y);
            if (grid.isLShape()) {
                float cut = grid.lRoomCutoutOverflow(px, py, 0.0f);
                if (cut > 0.0f) over += cut;
            }
        } else if (!grid.inBoundsPoint(px, py, 0.0f)) {
            over += 10.0f;
        }
        return over;
    };

    float pen = 0.0f;
    float centerOver = boundsOverflow(x, y);
    if (centerOver > 0.0f) pen += 1000.0f + centerOver * 20.0f;

    static constexpr float kD8 = 0.70710678f;
    static constexpr float kOx[9] = {0, -1, 1, 0, 0, -kD8, kD8, -kD8, kD8};
    static constexpr float kOy[9] = {0, 0, 0, -1, 1, -kD8, -kD8, kD8, kD8};
    float r = std::max(2.0f, radius - 1.0f);
    float invPx = (grid.pitch.x > 0.0f) ? (1.0f / grid.pitch.x) : 0.0f;
    float invPy = (grid.pitch.y > 0.0f) ? (1.0f / grid.pitch.y) : 0.0f;
    for (int i = 0; i < 9; ++i) {
        float px = x + kOx[i] * r;
        float py = y + kOy[i] * r;
        float over = boundsOverflow(px, py);
        if (over > 0.0f) {
            pen += 200.0f + over * 20.0f;
            continue;
        }
        int idx = -1;
        if (invPx > 0.0f && invPy > 0.0f) {
            float ux = (px - grid.origin.x) * invPx + 0.5f;
            float uy = (py - grid.origin.y) * invPy + 0.5f;
            int col = (ux >= 0.0f) ? static_cast<int>(ux) : static_cast<int>(std::floor(ux));
            int row = (uy >= 0.0f) ? static_cast<int>(uy) : static_cast<int>(std::floor(uy));
            if (col >= 0 && col < grid.width && row >= 0 && row < grid.height) {
                int candIdx = col + row * grid.width;
                if (candIdx < grid.cellCount) idx = candIdx;
            }
        }
        if (idx < 0) {
            pen += 200.0f;
            continue;
        }
        if (!grid.cellPhysicallyPassable(idx, canFly)) {
            int col = idx % grid.width;
            int row = idx / grid.width;
            float cx = grid.origin.x + static_cast<float>(col) * grid.pitch.x;
            float cy = grid.origin.y + static_cast<float>(row) * grid.pitch.y;
            float depth = std::min(std::max(0.0f, grid.pitch.x * 0.5f - std::abs(px - cx)),
                                   std::max(0.0f, grid.pitch.y * 0.5f - std::abs(py - cy)));
            pen += 100.0f * (1.0f + depth);
        }
    }
    return pen;
}

struct GridFastInfo {
    bool fastOpen = false;
    bool simpleRect = false;

    void init(const RoomGrid& grid) {
        simpleRect = !grid.beast && !grid.isLShape() && grid.pitch.x == 40.0f && grid.pitch.y == 40.0f;
        fastOpen = simpleRect && !grid.hasSolidCells;
    }

    bool footprintSafe(const RoomGrid& grid, float x, float y, float radius, bool canFly) const {
        if (fastOpen) {
            float r = std::max(2.0f, radius - 1.0f);
            return x - r >= grid.topLeft.x && x + r <= grid.bottomRight.x &&
                   y - r >= grid.topLeft.y && y + r <= grid.bottomRight.y;
        }
        return grid.footprintSafe(x, y, radius, canFly);
    }
};

// Advance one 60Hz player update (`pos += vel`, NOT `0.5 * vel`!) with physical terrain slide.
inline void stepPlayer60(const RoomGrid& grid, float playerSize, bool canFly,
                         bool originUnsafe, Vec2 dir, const PlayerKinematics& kin,
                         Vec2& pos, Vec2& vel, bool& moved) {
    if (dir.lengthSq() < 1e-6f) {
        vel = vel * kin.fIdle + kin.extAccel;
    } else {
        vel = vel * kin.fDrive + dir * kin.accel + kin.extAccel;
    }
    Vec2 delta = vel;
    float distSq = delta.lengthSq();
    if (distSq < 1e-8f) return;

    float fromPen = -1.0f;
    auto canMoveTo = [&](Vec2 q, Vec2 from) -> bool {
        if (grid.footprintSafe(q.x, q.y, playerSize, canFly)) return true;
        if (!originUnsafe) return false;
        if (grid.footprintSafe(from.x, from.y, playerSize, canFly)) return false;
        if (fromPen < 0.0f) fromPen = footprintPenalty(grid, from.x, from.y, playerSize, canFly);
        return footprintPenalty(grid, q.x, q.y, playerSize, canFly) < fromPen - 0.02f;
    };

    int sub = (distSq <= 36.0f) ? 1 : std::min(4, std::max(1, static_cast<int>(std::ceil(std::sqrt(distSq) / 6.0f))));
    for (int s = 0; s < sub; ++s) {
        Vec2 step = delta * (1.0f / static_cast<float>(sub));
        Vec2 cand = pos + step;
        if (canMoveTo(cand, pos)) {
            pos = cand;
            fromPen = -1.0f;
            moved = true;
            continue;
        }
        bool slideX = (std::abs(step.x) > 1e-4f) && canMoveTo({pos.x + step.x, pos.y}, pos);
        bool slideY = (std::abs(step.y) > 1e-4f) && canMoveTo({pos.x, pos.y + step.y}, pos);
        if (slideX && !slideY) {
            pos.x += step.x; vel.y = 0.0f; fromPen = -1.0f; moved = true;
        } else if (slideY && !slideX) {
            pos.y += step.y; vel.x = 0.0f; fromPen = -1.0f; moved = true;
        } else {
            vel = {0.0f, 0.0f};
            break;
        }
    }
}

// Specialized fast stepper for inner rollout loops: eliminates std::ceil/sqrt and virtual branches on open rooms.
inline void stepPlayer60Fast(const RoomGrid& grid, const GridFastInfo& gf,
                             float playerSize, bool canFly, bool originUnsafe,
                             bool dirZero, Vec2 dAccel, const PlayerKinematics& kin,
                             Vec2& pos, Vec2& vel, bool& moved) {
    if (dirZero) {
        vel = vel * kin.fIdle + kin.extAccel;
    } else {
        vel = vel * kin.fDrive + dAccel + kin.extAccel;
    }
    float distSq = vel.lengthSq();
    if (distSq < 1e-8f) return;

    if (gf.fastOpen && !originUnsafe) {
        float r = std::max(2.0f, playerSize - 1.0f);
        if (distSq <= 36.0f) {
            Vec2 cand{pos.x + vel.x, pos.y + vel.y};
            if (cand.x - r >= grid.topLeft.x && cand.x + r <= grid.bottomRight.x &&
                cand.y - r >= grid.topLeft.y && cand.y + r <= grid.bottomRight.y) {
                pos = cand;
                moved = true;
                return;
            }
            bool slideX = (std::abs(vel.x) > 1e-4f) &&
                          (pos.x + vel.x - r >= grid.topLeft.x && pos.x + vel.x + r <= grid.bottomRight.x &&
                           pos.y - r >= grid.topLeft.y && pos.y + r <= grid.bottomRight.y);
            bool slideY = (std::abs(vel.y) > 1e-4f) &&
                          (pos.x - r >= grid.topLeft.x && pos.x + r <= grid.bottomRight.x &&
                           pos.y + vel.y - r >= grid.topLeft.y && pos.y + vel.y + r <= grid.bottomRight.y);
            if (slideX && !slideY) {
                pos.x += vel.x; vel.y = 0.0f; moved = true;
            } else if (slideY && !slideX) {
                pos.y += vel.y; vel.x = 0.0f; moved = true;
            } else {
                vel = {0.0f, 0.0f};
            }
            return;
        }
    }

    Vec2 delta = vel;
    float fromPen = -1.0f;
    auto canMoveTo = [&](Vec2 q, Vec2 from) -> bool {
        if (gf.footprintSafe(grid, q.x, q.y, playerSize, canFly)) return true;
        if (!originUnsafe) return false;
        if (gf.footprintSafe(grid, from.x, from.y, playerSize, canFly)) return false;
        if (fromPen < 0.0f) fromPen = footprintPenalty(grid, from.x, from.y, playerSize, canFly);
        return footprintPenalty(grid, q.x, q.y, playerSize, canFly) < fromPen - 0.02f;
    };

    int sub = (distSq <= 36.0f) ? 1 : std::min(4, std::max(1, static_cast<int>(std::ceil(std::sqrt(distSq) / 6.0f))));
    for (int s = 0; s < sub; ++s) {
        Vec2 step = delta * (1.0f / static_cast<float>(sub));
        Vec2 cand = pos + step;
        if (canMoveTo(cand, pos)) {
            pos = cand;
            fromPen = -1.0f;
            moved = true;
            continue;
        }
        bool slideX = (std::abs(step.x) > 1e-4f) && canMoveTo({pos.x + step.x, pos.y}, pos);
        bool slideY = (std::abs(step.y) > 1e-4f) && canMoveTo({pos.x, pos.y + step.y}, pos);
        if (slideX && !slideY) {
            pos.x += step.x; vel.y = 0.0f; fromPen = -1.0f; moved = true;
        } else if (slideY && !slideX) {
            pos.y += step.y; vel.x = 0.0f; fromPen = -1.0f; moved = true;
        } else {
            vel = {0.0f, 0.0f};
            break;
        }
    }
}

// Ultra-fast zero-sqrt hard-only collision probe at step k (gm == 0).
// When minPen > 0, returns true iff a hard threat penetrates strictly deeper than minPen.
inline bool hitsHardAtStep(const ThreatScene& scene, PrecompThreats& pt,
                           Vec2 p0, Vec2 p1, float bodyRadius, bool bodyCanFly, int k,
                           float minPen = 0.0f) {
    float pMinX = std::min(p0.x, p1.x), pMaxX = std::max(p0.x, p1.x);
    float pMinY = std::min(p0.y, p1.y), pMaxY = std::max(p0.y, p1.y);
    int blk = k >> 3;

    // 1. Hard lasers
    for (int li = 0; li < pt.numLasers; ++li) {
        const LaserHazard& l = scene.lasers[li];
        if (l.warning) continue;
        PrecompLaser& pl = pt.lasersPtr[li];
        PrecompLaserStep& ps = pt.laserStepsPtr[pl.stepOffset + k];
        if (!ps.active) continue;
        float pad = bodyRadius + 1.0f;
        const ChunkBox& lcb = pl.chunks[blk];
        if (pMaxX + pad < lcb.minX || pMinX - pad > lcb.maxX ||
            pMaxY + pad < lcb.minY || pMinY - pad > lcb.maxY) {
            continue;
        }
        float radSum = bodyRadius + l.width - minPen;
        if (radSum <= 0.0f) continue;
        Vec2 a{p0.x - ps.orig0.x, p0.y - ps.orig0.y};
        Vec2 b{p1.x - ps.orig1.x, p1.y - ps.orig1.y};
        if (l.ring) {
            float nearSq = pointSegmentDistSq(0.0f, 0.0f, a.x, a.y, b.x, b.y);
            float outer = l.radius + radSum;
            if (nearSq >= outer * outer) continue;
            if (l.radius < radSum) return true;
            float inner = l.radius - radSum;
            if (std::max(a.lengthSq(), b.lengthSq()) > inner * inner) return true;
        } else {
            float effRad = radSum + ps.rotMargin;
            if (ps.twoPts) {
                if (std::max(a.x, b.x) + effRad < ps.sMinX || std::min(a.x, b.x) - effRad > ps.sMaxX ||
                    std::max(a.y, b.y) + effRad < ps.sMinY || std::min(a.y, b.y) - effRad > ps.sMaxY) {
                    continue;
                }
                float d2 = segmentSegmentDistSqPre(a.x, a.y, b.x, b.y,
                                                   ps.segA.x, ps.segA.y, ps.segDx, ps.segDy,
                                                   ps.segLenSq, ps.segInvLenSq);
                if (d2 < effRad * effRad) return true;
            } else {
                const Vec2* pts = ps.midZero ? l.pts : pt.getLaserRotPts(l, ps);
                float aMinX = std::min(a.x, b.x) - effRad, aMaxX = std::max(a.x, b.x) + effRad;
                float aMinY = std::min(a.y, b.y) - effRad, aMaxY = std::max(a.y, b.y) + effRad;
                if (aMaxX < ps.sMinX || aMinX > ps.sMaxX || aMaxY < ps.sMinY || aMinY > ps.sMaxY) {
                    continue;
                }
                float effSq = effRad * effRad;
                for (int i = 1; i < l.numPts; ++i) {
                    const Vec2& pA = pts[i - 1];
                    const Vec2& pB = pts[i];
                    if (std::max(pA.x, pB.x) < aMinX || std::min(pA.x, pB.x) > aMaxX ||
                        std::max(pA.y, pB.y) < aMinY || std::min(pA.y, pB.y) > aMaxY) {
                        continue;
                    }
                    if (segmentSegmentDistSq(a.x, a.y, b.x, b.y, pA.x, pA.y, pB.x, pB.y) < effSq) {
                        return true;
                    }
                }
            }
        }
    }

    // 2. Hard static discs
    if (pt.numStaticDiscs > 0) {
        float pSegDx = p1.x - p0.x, pSegDy = p1.y - p0.y;
        float pSegLenSq = pSegDx * pSegDx + pSegDy * pSegDy;
        float pSegInvLenSq = (pSegLenSq > 1e-6f) ? (1.0f / pSegLenSq) : 0.0f;
        for (int di = 0; di < pt.numStaticDiscs; ++di) {
            const StaticDisc& sd = pt.staticDiscsPtr[di];
            if (sd.warning || k < sd.lo || k > sd.hi) continue;
            if (sd.groundOnly && bodyCanFly) continue;
            float rs = bodyRadius + sd.radius - minPen;
            if (rs <= 0.0f) continue;
            if (pMaxX + rs < sd.pos.x || pMinX - rs > sd.pos.x ||
                pMaxY + rs < sd.pos.y || pMinY - rs > sd.pos.y) {
                continue;
            }
            float vx = sd.pos.x - p0.x, vy = sd.pos.y - p0.y;
            float u = (pSegInvLenSq > 0.0f) ? clamp01((vx * pSegDx + vy * pSegDy) * pSegInvLenSq) : 0.0f;
            float rx = vx - pSegDx * u, ry = vy - pSegDy * u;
            if (rx * rx + ry * ry < rs * rs) return true;
        }
    }

    // 3. Hard moving / capsule discs
    for (int mi = 0; mi < pt.numMovingDiscs; ++mi) {
        const MovingDisc& md = pt.movingDiscsPtr[mi];
        if (md.warning || k < md.lo || k > md.hi) continue;
        if (md.groundOnly && bodyCanFly) continue;
        float rs = bodyRadius + md.radius - minPen;
        if (rs <= 0.0f) continue;
        float pad = rs + 1.0f;
        const ChunkBox& mcb = md.chunks[blk];
        if (pMaxX + pad < mcb.minX || pMinX - pad > mcb.maxX ||
            pMaxY + pad < mcb.minY || pMinY - pad > mcb.maxY) {
            continue;
        }
        const Vec2* mdPts = pt.discPtsPtr + md.ptsOffset;
        const Vec2& q0 = mdPts[k * 2];
        const Vec2& q1 = mdPts[k * 2 + 1];
        if (pMaxX + rs < std::min(q0.x, q1.x) || pMinX - rs > std::max(q0.x, q1.x) ||
            pMaxY + rs < std::min(q0.y, q1.y) || pMinY - rs > std::max(q0.y, q1.y)) {
            continue;
        }
        if (md.isCapsule) {
            if (segmentSegmentDistSq(p0.x, p0.y, p1.x, p1.y, q0.x, q0.y, q1.x, q1.y) < rs * rs) return true;
        } else {
            float rx0 = p0.x - q0.x, ry0 = p0.y - q0.y;
            float rvx = (p1.x - p0.x) - (q1.x - q0.x);
            float rvy = (p1.y - p0.y) - (q1.y - q0.y);
            float lenSq = rvx * rvx + rvy * rvy;
            float u = (lenSq > 1e-6f) ? clamp01(-(rx0 * rvx + ry0 * rvy) / lenSq) : 0.0f;
            float cx = rx0 + rvx * u, cy = ry0 + rvy * u;
            if (cx * cx + cy * cy < rs * rs) return true;
        }
    }

    // 4. Hard bullets
    const ChunkBox* row = pt.bulletChunksPtr + blk * pt.numBullets;
    for (int bi = 0; bi < pt.numBullets; ++bi) {
        const ActiveBullet& ab = pt.bulletsPtr[bi];
        if (ab.warning || k < ab.lo || k > ab.hi) continue;
        float rs = bodyRadius + ab.radius - minPen;
        if (rs <= 0.0f) continue;
        float pad = rs + 1.0f;
        const ChunkBox& cb = row[bi];
        if (pMaxX + pad < cb.minX || pMinX - pad > cb.maxX ||
            pMaxY + pad < cb.minY || pMinY - pad > cb.maxY) {
            continue;
        }
        const BulletTrack& b = scene.bullets[ab.idx];
        Vec2 q0 = (k == 0) ? b.pts[0] : b.pts[k - 1];
        const Vec2& q1 = b.pts[k];
        if (pMaxX + rs < std::min(q0.x, q1.x) || pMinX - rs > std::max(q0.x, q1.x) ||
            pMaxY + rs < std::min(q0.y, q1.y) || pMinY - rs > std::max(q0.y, q1.y)) {
            continue;
        }
        float rx0 = p0.x - q0.x, ry0 = p0.y - q0.y;
        float rvx = (p1.x - p0.x) - (q1.x - q0.x);
        float rvy = (p1.y - p0.y) - (q1.y - q0.y);
        float lenSq = rvx * rvx + rvy * rvy;
        float u = (lenSq > 1e-6f) ? clamp01(-(rx0 * rvx + ry0 * rvy) / lenSq) : 0.0f;
        float cx = rx0 + rvx * u, cy = ry0 + rvy * u;
        if (cx * cx + cy * cy < rs * rs) return true;
    }

    return false;
}

// Single-step hazard evaluator for early-abort step-major loops.
// Returns true if aborted early (updating st.hasHard/firstHardK/lastHardK/hasWarn/crossedAutoAvoid).
inline bool evalBodyAtStep(const ThreatScene& scene, PrecompThreats& pt,
                           Vec2 p0, Vec2 p1, float bodyRadius, bool bodyCanFly,
                           int k, int maxK, bool onlyEndGap,
                           float& hardMax, float& warnMax, float& minGap,
                           RolloutState& st, bool abortHard, bool abortWarn) {
    float gm = (!onlyEndGap || k == maxK) ? 24.0f : 0.0f;
    float pMinX = std::min(p0.x, p1.x), pMaxX = std::max(p0.x, p1.x);
    float pMinY = std::min(p0.y, p1.y), pMaxY = std::max(p0.y, p1.y);
    int blk = k >> 3;

    // 1. Lasers (long beams often dominate early aborts)
    for (int li = 0; li < pt.numLasers; ++li) {
        PrecompLaser& pl = pt.lasersPtr[li];
        PrecompLaserStep& ps = pt.laserStepsPtr[pl.stepOffset + k];
        if (!ps.active) continue;
        float pad = bodyRadius + gm + 1.0f;
        const ChunkBox& lcb = pl.chunks[blk];
        if (pMaxX + pad < lcb.minX || pMinX - pad > lcb.maxX ||
            pMaxY + pad < lcb.minY || pMinY - pad > lcb.maxY) {
            continue;
        }
        const LaserHazard& l = scene.lasers[li];
        float pen = laserClearanceAtStepPre(l, ps, &pt, p0, p1, bodyRadius, gm);
        if (pen > 0.0f) {
            if (l.warning) {
                warnMax = std::max(warnMax, pen);
                if (abortWarn) { st.hasWarn = true; return true; }
            } else {
                hardMax = std::max(hardMax, pen);
                if (abortHard || abortWarn) {
                    st.hasHard = true;
                    st.firstHardK = std::min(st.firstHardK, k);
                    st.lastHardK = std::max(st.lastHardK, k);
                    return true;
                }
            }
            minGap = 0.0f;
        } else if (pen > -1e5f) {
            minGap = std::min(minGap, -pen);
        }
    }

    // 2. Static discs (fast point-to-segment test with precomputed step segment invLenSq)
    float pSegDx = p1.x - p0.x, pSegDy = p1.y - p0.y;
    float pSegLenSq = pSegDx * pSegDx + pSegDy * pSegDy;
    float pSegInvLenSq = (pSegLenSq > 1e-6f) ? (1.0f / pSegLenSq) : 0.0f;
    for (int di = 0; di < pt.numStaticDiscs; ++di) {
        const StaticDisc& sd = pt.staticDiscsPtr[di];
        if (k < sd.lo || k > sd.hi) continue;
        if (sd.groundOnly && bodyCanFly) continue;
        float rs = bodyRadius + sd.radius;
        float bound = rs + gm;
        if (pMaxX + bound < sd.pos.x || pMinX - bound > sd.pos.x ||
            pMaxY + bound < sd.pos.y || pMinY - bound > sd.pos.y) {
            continue;
        }
        float vx = sd.pos.x - p0.x, vy = sd.pos.y - p0.y;
        float u = (pSegInvLenSq > 0.0f) ? clamp01((vx * pSegDx + vy * pSegDy) * pSegInvLenSq) : 0.0f;
        float rx = vx - pSegDx * u, ry = vy - pSegDy * u;
        float distSq = rx * rx + ry * ry;
        if (distSq < bound * bound) {
            bool skipSqrt = (!sd.warning && (abortHard || abortWarn) && distSq < rs * rs);
            float pen = skipSqrt ? 1.0f : (rs - std::sqrt(distSq));
            if (pen > 0.0f) {
                if (sd.warning) {
                    warnMax = std::max(warnMax, pen);
                    if (abortWarn) { st.hasWarn = true; return true; }
                } else {
                    hardMax = std::max(hardMax, pen);
                    if (abortHard || abortWarn) {
                        st.hasHard = true;
                        st.firstHardK = std::min(st.firstHardK, k);
                        st.lastHardK = std::max(st.lastHardK, k);
                        return true;
                    }
                }
                minGap = 0.0f;
            } else {
                minGap = std::min(minGap, -pen);
            }
        }
    }

    // 3. Moving / capsule discs
    for (int mi = 0; mi < pt.numMovingDiscs; ++mi) {
        const MovingDisc& md = pt.movingDiscsPtr[mi];
        if (k < md.lo || k > md.hi) continue;
        if (md.groundOnly && bodyCanFly) continue;
        float pad = md.radius + bodyRadius + gm + 1.0f;
        const ChunkBox& mcb = md.chunks[blk];
        if (pMaxX + pad < mcb.minX || pMinX - pad > mcb.maxX ||
            pMaxY + pad < mcb.minY || pMinY - pad > mcb.maxY) {
            continue;
        }
        float rs = bodyRadius + md.radius;
        const Vec2* mdPts = pt.discPtsPtr + md.ptsOffset;
        float pen = md.isCapsule
            ? sweptCapsuleClearance(p0, p1, mdPts[k * 2], mdPts[k * 2 + 1], rs, gm)
            : sweptRelativeClearanceFast(p0, p1, pMinX, pMaxX, pMinY, pMaxY,
                                         mdPts[k * 2], mdPts[k * 2 + 1], rs, gm, !md.warning && (abortHard || abortWarn));
        if (pen > 0.0f) {
            if (md.warning) {
                warnMax = std::max(warnMax, pen);
                if (abortWarn) { st.hasWarn = true; return true; }
            } else {
                hardMax = std::max(hardMax, pen);
                if (abortHard || abortWarn) {
                    st.hasHard = true;
                    st.firstHardK = std::min(st.firstHardK, k);
                    st.lastHardK = std::max(st.lastHardK, k);
                    return true;
                }
            }
            minGap = 0.0f;
        } else {
            minGap = std::min(minGap, -pen);
        }
    }

    // 4. Bullets using compact L1-resident chunk AABBs for block `blk`
    const ChunkBox* row = pt.bulletChunksPtr + blk * pt.numBullets;
    for (int bi = 0; bi < pt.numBullets; ++bi) {
        const ActiveBullet& ab = pt.bulletsPtr[bi];
        if (k < ab.lo || k > ab.hi) continue;
        float pad = ab.radius + bodyRadius + gm + 1.0f;
        const ChunkBox& cb = row[bi];
        if (pMaxX + pad < cb.minX || pMinX - pad > cb.maxX ||
            pMaxY + pad < cb.minY || pMinY - pad > cb.maxY) {
            continue;
        }
        const BulletTrack& b = scene.bullets[ab.idx];
        Vec2 q0 = (k == 0) ? b.pts[0] : b.pts[k - 1];
        float rs = bodyRadius + ab.radius;
        float pen = sweptRelativeClearanceFast(p0, p1, pMinX, pMaxX, pMinY, pMaxY,
                                               q0, b.pts[k], rs, gm, !ab.warning && (abortHard || abortWarn));
        if (pen > 0.0f) {
            if (ab.warning) {
                warnMax = std::max(warnMax, pen);
                if (abortWarn) { st.hasWarn = true; return true; }
            } else {
                hardMax = std::max(hardMax, pen);
                if (abortHard || abortWarn) {
                    st.hasHard = true;
                    st.firstHardK = std::min(st.firstHardK, k);
                    st.lastHardK = std::max(st.lastHardK, k);
                    return true;
                }
            }
            minGap = 0.0f;
        } else {
            minGap = std::min(minGap, -pen);
        }
    }

    // 5. AUTO-only pickup/pedestal/mimic cells
    if (k >= 1 && pt.gridHasAutoAvoid) {
        int idx = scene.grid.indexAt(p1.x, p1.y);
        if (scene.grid.cellAutoAvoid(idx)) {
            st.crossedAutoAvoid = true;
            st.hasWarn = true;
            if (abortWarn) return true;
        }
    }
    return false;
}

// Block-accelerated range hazard evaluator (no early abort; fills stepHardMax/WarnMax/MinGap/AutoAvoid).
inline void evalBodyRangeBlocked(const ThreatScene& scene, PrecompThreats& pt,
                                 const Vec2* path, const ChunkBox pChunks[8],
                                 float pMinX, float pMaxX, float pMinY, float pMaxY,
                                 float bodyRadius, bool bodyCanFly,
                                 int kStart, int kEnd, int maxK, float nonEndGm,
                                 float* stepHardMax, float* stepWarnMax, float* stepMinGap,
                                 uint8_t* stepAutoAvoid) {
    if (kStart > kEnd) return;
    int blkStart = kStart >> 3;
    int blkEnd = kEnd >> 3;

    // 1. Bullets (global AABB -> 8-step chunk AABB -> step segment)
    for (int bi = 0; bi < pt.numBullets; ++bi) {
        const ActiveBullet& ab = pt.bulletsPtr[bi];
        int lo = std::max(kStart, ab.lo);
        int hi = std::min(kEnd, ab.hi);
        if (lo > hi) continue;
        float maxGm = (hi == maxK) ? 24.0f : nonEndGm;
        float gPad = ab.radius + bodyRadius + maxGm + 1.0f;
        if (pMaxX + gPad < ab.minX || pMinX - gPad > ab.maxX ||
            pMaxY + gPad < ab.minY || pMinY - gPad > ab.maxY) {
            continue;
        }
        const BulletTrack& b = scene.bullets[ab.idx];
        float rs = bodyRadius + ab.radius;
        int bBlk0 = lo >> 3;
        int bBlk1 = hi >> 3;
        for (int blk = bBlk0; blk <= bBlk1; ++blk) {
            int cLo = std::max(lo, blk * 8);
            int cHi = std::min(hi, blk * 8 + 7);
            float blkGm = (cHi == maxK) ? 24.0f : nonEndGm;
            float cPad = rs + blkGm + 1.0f;
            const ChunkBox& pcb = pChunks[blk];
            const ChunkBox& bcb = pt.bulletChunksPtr[blk * pt.numBullets + bi];
            if (pcb.maxX + cPad < bcb.minX || pcb.minX - cPad > bcb.maxX ||
                pcb.maxY + cPad < bcb.minY || pcb.minY - cPad > bcb.maxY) {
                continue;
            }
            for (int k = cLo; k <= cHi; ++k) {
                Vec2 p0 = (k == 0) ? path[0] : path[k - 1];
                Vec2 q0 = (k == 0) ? b.pts[0] : b.pts[k - 1];
                float gm = (k == maxK) ? 24.0f : nonEndGm;
                float pen = sweptRelativeClearance(p0, path[k], q0, b.pts[k], rs, gm);
                if (pen > 0.0f) {
                    if (ab.warning) stepWarnMax[k] = std::max(stepWarnMax[k], pen);
                    else            stepHardMax[k] = std::max(stepHardMax[k], pen);
                    stepMinGap[k] = 0.0f;
                } else {
                    stepMinGap[k] = std::min(stepMinGap[k], -pen);
                }
            }
        }
    }

    // 2. Static discs (point-segment distance)
    for (int di = 0; di < pt.numStaticDiscs; ++di) {
        const StaticDisc& sd = pt.staticDiscsPtr[di];
        if (sd.groundOnly && bodyCanFly) continue;
        int lo = std::max(kStart, sd.lo);
        int hi = std::min(kEnd, sd.hi);
        if (lo > hi) continue;
        float rs = bodyRadius + sd.radius;
        float maxGm = (hi == maxK) ? 24.0f : nonEndGm;
        float gBound = rs + maxGm;
        if (pMaxX + gBound < sd.pos.x || pMinX - gBound > sd.pos.x ||
            pMaxY + gBound < sd.pos.y || pMinY - gBound > sd.pos.y) {
            continue;
        }
        int dBlk0 = lo >> 3;
        int dBlk1 = hi >> 3;
        for (int blk = dBlk0; blk <= dBlk1; ++blk) {
            int cLo = std::max(lo, blk * 8);
            int cHi = std::min(hi, blk * 8 + 7);
            float blkGm = (cHi == maxK) ? 24.0f : nonEndGm;
            float bBound = rs + blkGm;
            const ChunkBox& pcb = pChunks[blk];
            if (pcb.maxX + bBound < sd.pos.x || pcb.minX - bBound > sd.pos.x ||
                pcb.maxY + bBound < sd.pos.y || pcb.minY - bBound > sd.pos.y) {
                continue;
            }
            for (int k = cLo; k <= cHi; ++k) {
                Vec2 p0 = (k == 0) ? path[0] : path[k - 1];
                float gm = (k == maxK) ? 24.0f : nonEndGm;
                float bound = rs + gm;
                if (std::max(p0.x, path[k].x) + bound < sd.pos.x || std::min(p0.x, path[k].x) - bound > sd.pos.x ||
                    std::max(p0.y, path[k].y) + bound < sd.pos.y || std::min(p0.y, path[k].y) - bound > sd.pos.y) {
                    continue;
                }
                float d2 = pointSegmentDistSq(sd.pos.x, sd.pos.y, p0.x, p0.y, path[k].x, path[k].y);
                if (d2 >= bound * bound) continue;
                float pen = rs - std::sqrt(d2);
                if (pen > 0.0f) {
                    if (sd.warning) stepWarnMax[k] = std::max(stepWarnMax[k], pen);
                    else            stepHardMax[k] = std::max(stepHardMax[k], pen);
                    stepMinGap[k] = 0.0f;
                } else {
                    stepMinGap[k] = std::min(stepMinGap[k], -pen);
                }
            }
        }
    }

    // 3. Moving / capsule discs
    for (int mi = 0; mi < pt.numMovingDiscs; ++mi) {
        const MovingDisc& md = pt.movingDiscsPtr[mi];
        if (md.groundOnly && bodyCanFly) continue;
        int lo = std::max(kStart, md.lo);
        int hi = std::min(kEnd, md.hi);
        if (lo > hi) continue;
        float rs = bodyRadius + md.radius;
        float maxGm = (hi == maxK) ? 24.0f : nonEndGm;
        float gPad = rs + maxGm + 1.0f;
        if (pMaxX + gPad < md.minX || pMinX - gPad > md.maxX ||
            pMaxY + gPad < md.minY || pMinY - gPad > md.maxY) {
            continue;
        }
        int mBlk0 = lo >> 3;
        int mBlk1 = hi >> 3;
        for (int blk = mBlk0; blk <= mBlk1; ++blk) {
            int cLo = std::max(lo, blk * 8);
            int cHi = std::min(hi, blk * 8 + 7);
            float blkGm = (cHi == maxK) ? 24.0f : nonEndGm;
            float cPad = rs + blkGm + 1.0f;
            const ChunkBox& pcb = pChunks[blk];
            const ChunkBox& mcb = md.chunks[blk];
            if (pcb.maxX + cPad < mcb.minX || pcb.minX - cPad > mcb.maxX ||
                pcb.maxY + cPad < mcb.minY || pcb.minY - cPad > mcb.maxY) {
                continue;
            }
            const Vec2* mdPts = pt.discPtsPtr + md.ptsOffset;
            for (int k = cLo; k <= cHi; ++k) {
                Vec2 p0 = (k == 0) ? path[0] : path[k - 1];
                float gm = (k == maxK) ? 24.0f : nonEndGm;
                float pen = md.isCapsule
                    ? sweptCapsuleClearance(p0, path[k], mdPts[k * 2], mdPts[k * 2 + 1], rs, gm)
                    : sweptRelativeClearance(p0, path[k], mdPts[k * 2], mdPts[k * 2 + 1], rs, gm);
                if (pen > 0.0f) {
                    if (md.warning) stepWarnMax[k] = std::max(stepWarnMax[k], pen);
                    else            stepHardMax[k] = std::max(stepHardMax[k], pen);
                    stepMinGap[k] = 0.0f;
                } else {
                    stepMinGap[k] = std::min(stepMinGap[k], -pen);
                }
            }
        }
    }

    // 4. Lasers
    for (int li = 0; li < pt.numLasers; ++li) {
        PrecompLaser& pl = pt.lasersPtr[li];
        int lo = std::max(kStart, pl.firstActiveK);
        int hi = std::min(kEnd, pl.lastActiveK);
        if (lo > hi) continue;
        float maxGm = (hi == maxK) ? 24.0f : nonEndGm;
        float gPad = bodyRadius + maxGm + 1.0f;
        if (pMaxX + gPad < pl.minX || pMinX - gPad > pl.maxX ||
            pMaxY + gPad < pl.minY || pMinY - gPad > pl.maxY) {
            continue;
        }
        const LaserHazard& l = scene.lasers[li];
        int lBlk0 = lo >> 3;
        int lBlk1 = hi >> 3;
        for (int blk = std::max(blkStart, lBlk0); blk <= std::min(blkEnd, lBlk1); ++blk) {
            int cLo = std::max(lo, blk * 8);
            int cHi = std::min(hi, blk * 8 + 7);
            float blkGm = (cHi == maxK) ? 24.0f : nonEndGm;
            float cPad = bodyRadius + blkGm + 1.0f;
            const ChunkBox& pcb = pChunks[blk];
            const ChunkBox& lcb = pl.chunks[blk];
            if (pcb.maxX + cPad < lcb.minX || pcb.minX - cPad > lcb.maxX ||
                pcb.maxY + cPad < lcb.minY || pcb.minY - cPad > lcb.maxY) {
                continue;
            }
            for (int k = cLo; k <= cHi; ++k) {
                PrecompLaserStep& ps = pt.laserStepsPtr[pl.stepOffset + k];
                if (!ps.active) continue;
                Vec2 p0 = (k == 0) ? path[0] : path[k - 1];
                float gm = (k == maxK) ? 24.0f : nonEndGm;
                float pen = laserClearanceAtStepPre(l, ps, &pt, p0, path[k], bodyRadius, gm);
                if (pen > 0.0f) {
                    if (l.warning) stepWarnMax[k] = std::max(stepWarnMax[k], pen);
                    else           stepHardMax[k] = std::max(stepHardMax[k], pen);
                    stepMinGap[k] = 0.0f;
                } else if (pen > -1e5f) {
                    stepMinGap[k] = std::min(stepMinGap[k], -pen);
                }
            }
        }
    }

    // 5. AUTO-only pickup/pedestal/mimic cells
    if (pt.gridHasAutoAvoid) {
        for (int k = std::max(1, kStart); k <= kEnd; ++k) {
            int idx = scene.grid.indexAt(path[k].x, path[k].y);
            if (scene.grid.cellAutoAvoid(idx)) {
                stepAutoAvoid[k] = 1;
            }
        }
    }
}

inline void accumulateRolloutSteps(int kStart, int kEnd, int maxK,
                                   const float* stepHardMax, const float* stepWarnMax,
                                   const float* stepMinGap, const uint8_t* stepAutoAvoid,
                                   RolloutState& st) {
    for (int k = kStart; k <= kEnd; ++k) {
        if (stepAutoAvoid[k]) {
            st.crossedAutoAvoid = true;
            st.hasWarn = true;
        }
        float h = stepHardMax[k];
        float w = stepWarnMax[k];
        if (h > 0.0f) {
            st.hasHard = true;
            st.firstHardK = std::min(st.firstHardK, k);
            st.lastHardK = std::max(st.lastHardK, k);
            if (k >= 1) {
                ++st.hardHitSteps;
                st.hardExposure += std::min(100.0f, h);
            }
            st.maxHardPen = std::max(st.maxHardPen, h);
        }
        if (w > 0.0f) {
            st.hasWarn = true;
            st.maxWarnPen = std::max(st.maxWarnPen, w);
            if (k >= 1) {
                st.warnWeighted += std::min(100.0f, w) * static_cast<float>(maxK - k + 1) * 0.25f;
            }
        }
        if (k >= 1) {
            st.minClearance = std::min(st.minClearance, stepMinGap[k]);
        }
        if (k == maxK) {
            st.endHardPen = h;
            st.endClearance = stepMinGap[k];
        }
    }
}

struct SpaceBfsCache {
    struct EnemyBody {
        Vec2 pos;
        float radSum;
    };
    static constexpr int kInlineEnemies = 32;

    int16_t cost[Offsets::Room::kMaxGridCells]{};
    uint8_t blockedCell[Offsets::Room::kMaxGridCells]{};
    uint16_t seenStamp[Offsets::Room::kMaxGridCells]{};
    uint16_t curStamp = 0;

    int numEnemies = 0;
    EnemyBody inlineEnemies[kInlineEnemies]{};
    std::vector<EnemyBody> extraEnemies;
    const EnemyBody* enemiesPtr = nullptr;

    void init(const ThreatScene& scene) {
        const RoomGrid& g = scene.grid;
        for (int i = 0; i < g.cellCount; ++i) {
            cost[i] = -1;
            blockedCell[i] = 0;
            seenStamp[i] = 0;
        }
        curStamp = 0;
        numEnemies = 0;
        extraEnemies.clear();

        // Mark enemy bodies and static floor hazards so BFS never treats choked/spiked corners as open escape space
        for (const DiscHazard& d : scene.discs) {
            if (d.isEnemyBody) {
                EnemyBody eb{d.pos, d.radius + scene.player.size};
                if (extraEnemies.empty() && numEnemies < kInlineEnemies) {
                    inlineEnemies[numEnemies++] = eb;
                } else {
                    if (extraEnemies.empty()) extraEnemies.assign(inlineEnemies, inlineEnemies + numEnemies);
                    extraEnemies.push_back(eb);
                    ++numEnemies;
                }
            }
            bool staticHazard = (d.warning == 0 && !d.autoOnly && d.fromT <= 0.5f &&
                                 d.vel.lengthSq() < 0.25f && (!d.groundOnly || !scene.player.canFly));
            if (!d.isEnemyBody && !staticHazard) continue;
            float r = d.radius + scene.player.size + (d.isEnemyBody ? 4.0f : 0.0f);
            float rSq = r * r;
            int c0 = std::max(0, static_cast<int>(std::floor((d.pos.x - r - g.origin.x) / g.pitch.x + 0.5f)));
            int c1 = std::min(g.width - 1, static_cast<int>(std::floor((d.pos.x + r - g.origin.x) / g.pitch.x + 0.5f)));
            int r0 = std::max(0, static_cast<int>(std::floor((d.pos.y - r - g.origin.y) / g.pitch.y + 0.5f)));
            int r1 = std::min(g.height - 1, static_cast<int>(std::floor((d.pos.y + r - g.origin.y) / g.pitch.y + 0.5f)));
            for (int ry = r0; ry <= r1; ++ry) {
                float cy = g.origin.y + static_cast<float>(ry) * g.pitch.y;
                for (int cx = c0; cx <= c1; ++cx) {
                    int idx = cx + ry * g.width;
                    if (idx >= 0 && idx < g.cellCount) {
                        float ddx = (g.origin.x + static_cast<float>(cx) * g.pitch.x) - d.pos.x;
                        float ddy = cy - d.pos.y;
                        if (ddx * ddx + ddy * ddy <= rSq) {
                            blockedCell[idx] = 1;
                        }
                    }
                }
            }
        }
        enemiesPtr = extraEnemies.empty() ? inlineEnemies : extraEnemies.data();
    }
};

inline int scoreEndpointSpace(const ThreatScene& scene, Vec2 endpoint, SpaceBfsCache& cache) {
    const RoomGrid& g = scene.grid;
    if (!g.inBoundsPoint(endpoint.x, endpoint.y, 0.0f)) return 999;
    int idx = g.indexAt(endpoint.x, endpoint.y);
    if (idx < 0 || !g.cellPhysicallyPassable(idx, scene.player.canFly)) return 999;

    int baseCost = cache.cost[idx];
    if (baseCost < 0) {
        if (++cache.curStamp == 0) {
            std::fill_n(cache.seenStamp, g.cellCount, uint16_t(0));
            cache.curStamp = 1;
        }
        uint16_t stamp = cache.curStamp;
        int16_t qx[48], qy[48];
        int depth[48];
        int head = 0, tail = 0, exits = 0, reach = 0;
        int sx = idx % g.width;
        int sy = idx / g.width;
        qx[tail] = static_cast<int16_t>(sx); qy[tail] = static_cast<int16_t>(sy); depth[tail] = 0; ++tail;
        cache.seenStamp[idx] = stamp;

        static constexpr int kDx[4] = {-1, 1, 0, 0};
        static constexpr int kDy[4] = {0, 0, -1, 1};
        while (head < tail && tail < 48) {
            int cx = qx[head];
            int cy = qy[head];
            int dp = depth[head];
            ++head;
            ++reach;
            if (dp < 4) {
                for (int d = 0; d < 4; ++d) {
                    int nx = cx + kDx[d], ny = cy + kDy[d];
                    if (nx < 0 || nx >= g.width || ny < 0 || ny >= g.height) continue;
                    int ni = nx + ny * g.width;
                    if (ni >= g.cellCount) continue;
                    if (!g.cellPhysicallyPassable(ni, scene.player.canFly) || cache.blockedCell[ni]) continue;
                    float ncx = g.origin.x + static_cast<float>(nx) * g.pitch.x;
                    float ncy = g.origin.y + static_cast<float>(ny) * g.pitch.y;
                    if (!g.inBoundsPoint(ncx, ncy, 4.0f)) continue;
                    if (dp == 0) ++exits;
                    if (cache.seenStamp[ni] != stamp && tail < 48) {
                        cache.seenStamp[ni] = stamp;
                        qx[tail] = static_cast<int16_t>(nx);
                        qy[tail] = static_cast<int16_t>(ny);
                        depth[tail] = dp + 1;
                        ++tail;
                    }
                }
            }
        }
        baseCost = (41 - std::min(41, reach)) * 12 + (4 - std::min(4, exits)) * 70;
        cache.cost[idx] = static_cast<int16_t>(baseCost);
    }

    int cost = baseCost;
    float wallClear = g.wallClearance(endpoint.x, endpoint.y);
    if (wallClear < 24.0f) {
        cost += static_cast<int>((24.0f - wallClear) * 4.0f);
    }

    // Enemy encirclement penalty so safe dodges steer away from surrounding monster packs
    int crowdPen = 0;
    for (int ei = 0; ei < cache.numEnemies; ++ei) {
        const auto& eb = cache.enemiesPtr[ei];
        float dx = endpoint.x - eb.pos.x;
        float dy = endpoint.y - eb.pos.y;
        if (std::abs(dx) >= 140.0f || std::abs(dy) >= 140.0f) continue;
        float distSq = dx * dx + dy * dy;
        if (distSq < 140.0f * 140.0f) {
            float clear = std::sqrt(distSq) - eb.radSum;
            if (clear < 110.0f) {
                crowdPen += static_cast<int>((110.0f - std::max(0.0f, clear)) * 0.45f);
            }
        }
    }
    cost += std::min(300, crowdPen);
    return std::min(999, std::max(0, cost));
}

// Quantized score strictly aligned with PlanResult::kScale (1048576.0) integer tiers (dodge_planner.lua:88-168).
inline double computeRolloutScore(const ThreatScene& scene, const RolloutState& fast,
                                  const RolloutState& slow, bool inside, int maxK,
                                  int dir1, int prevChosen, int rawDir, bool isTurn,
                                  SpaceBfsCache& cache) {
    static constexpr double kScale = PlanResult::kScale;

    bool hasHard = fast.hasHard || slow.hasHard;
    bool hasWarn = fast.hasWarn || slow.hasWarn;
    bool crossedAuto = fast.crossedAutoAvoid || slow.crossedAutoAvoid;
    int64_t intRisk = 0;
    int exitTie = 0;

    if (hasHard) {
        int firstHit = std::min(fast.firstHardK, slow.firstHardK);
        int lastHit = std::max(fast.lastHardK, slow.lastHardK);
        int hits = std::max(fast.hardHitSteps, slow.hardHitSteps);
        float maxPen = std::max(fast.maxHardPen, slow.maxHardPen);
        float endPen = std::max(fast.endHardPen, slow.endHardPen);
        float exposure = std::max(fast.hardExposure, slow.hardExposure);

        if (inside) {
            if (lastHit < maxK) {
                // Keep primary exit tick strictly ahead of warning tie-break (wTier <= 9999)
                // so a bomb warning disc never swamps hard exit time or breaks Regime A pruning.
                intRisk = 1000000LL + static_cast<int64_t>(std::max(0, lastHit) + 1) * 10000LL;
                exitTie = std::min(499, hits * 8 + std::min(200, static_cast<int>(exposure * 0.5f)));
            } else {
                // Cannot exit pool/beam within horizon: rank by terminal penetration depth so player runs to nearest edge!
                int depthBucket = std::min(999, static_cast<int>(std::floor(std::max(0.0f, endPen) * 4.0f)));
                int expBucket = std::min(999, hits * 10 + std::min(200, static_cast<int>(exposure * 0.1f)));
                intRisk = 2000000LL + static_cast<int64_t>(depthBucket) * 1000LL + static_cast<int64_t>(expBucket);
            }
        } else {
            int survival = std::max(1, maxK + 2 - std::max(1, firstHit));
            int64_t trapped = (lastHit >= maxK) ? 200000LL : 0LL;
            int64_t sub = std::min<int64_t>(
                989999LL,
                trapped + static_cast<int64_t>(std::floor(maxPen * 2000.0f + exposure * 50.0f + hits * 100.0f)));
            intRisk = static_cast<int64_t>(survival) * 1000000LL + sub;
        }
    }

    if (hasWarn) {
        float wWeighted = std::max(fast.warnWeighted, slow.warnWeighted);
        float wPeak = std::max(fast.maxWarnPen, slow.maxWarnPen);
        // When !hasHard (e.g. standing on a bomb warning), allow up to 99999 (< 600000 autoAvoid)
        // so large bomb radii over 46-60 ticks never saturate all directions to a flat 9999 tie.
        int64_t wCap = hasHard ? 9999LL : 99999LL;
        int64_t wTier = std::max<int64_t>(1LL, std::min<int64_t>(wCap, static_cast<int64_t>(std::ceil(wWeighted + wPeak * 0.5f))));
        intRisk += wTier;
    }
    if (crossedAuto) {
        // Above combat.lua's +500*SCALE soft-warning slack, yet below 1,000,000 hard collision!
        intRisk = std::max<int64_t>(intRisk, 600000LL);
    }

    int space = std::max(scoreEndpointSpace(scene, fast.pos, cache), scoreEndpointSpace(scene, slow.pos, cache));
    float endGap = std::min(fast.endClearance, slow.endClearance);
    int cost = std::min(999, static_cast<int>(space * 0.6f + std::max(0.0f, 24.0f - endGap) * 8.0f));

    // L1 directional alignment with manual input + hysteresis stickiness
    int rawIdx = (rawDir >= 0 && rawDir < 9) ? rawDir : 0;
    int dIdx = (dir1 >= 0 && dir1 < 9) ? dir1 : 0;
    int l1 = std::abs(kCandIntX[dIdx] - kCandIntX[rawIdx]) + std::abs(kCandIntY[dIdx] - kCandIntY[rawIdx]);
    int pref = l1 * 6;
    if (rawIdx != 0 && dIdx == 0) {
        pref += 10; // prefer adjacent diagonal glide over stopping dead when holding a key
    } else if (rawIdx != 0 && dIdx != 0 &&
               (kCandIntX[dIdx] * kCandIntX[rawIdx] + kCandIntY[dIdx] * kCandIntY[rawIdx]) < 0) {
        pref += 10; // penalize 180/135-deg reversal vs 45/90-deg sidestep
    }
    if (prevChosen >= 0 && dIdx != prevChosen) pref += 6;
    if (isTurn) pref += 64;

    double tie = static_cast<double>(std::min(1023, cost)) * 1024.0 +
                 static_cast<double>(std::min(1023, pref + exitTie));

    if (intRisk <= 0) {
        return tie - kScale;
    }
    return static_cast<double>(intRisk) * kScale + tie;
}

inline RolloutSnapshot makeSnap(const RolloutState& st, Vec2 p, Vec2 v, Vec2 tp, Vec2 tv, bool moved) {
    RolloutSnapshot sn{};
    sn.pos = p;
    sn.vel = v;
    sn.twinPos = tp;
    sn.twinVel = tv;
    sn.moved = moved;
    sn.hasHard = st.hasHard;
    sn.hasWarn = st.hasWarn;
    sn.crossedAutoAvoid = st.crossedAutoAvoid;
    sn.firstHardK = st.firstHardK;
    sn.lastHardK = st.lastHardK;
    sn.hardHitSteps = st.hardHitSteps;
    sn.maxHardPen = st.maxHardPen;
    sn.endHardPen = st.endHardPen;
    sn.hardExposure = st.hardExposure;
    sn.maxWarnPen = st.maxWarnPen;
    sn.warnWeighted = st.warnWeighted;
    sn.minClearance = st.minClearance;
    sn.endClearance = st.endClearance;
    return sn;
}

inline void simulateStraight(const ThreatScene& scene, PrecompThreats& pt,
                             const GridFastInfo& gf,
                             int dir, int rawDir,
                             bool originUnsafe, bool twinOriginUnsafe,
                             const PlayerKinematics& kin, const PlayerKinematics& twinKin,
                             int maxK, const int pivots[3], bool recordSnaps,
                             RolloutState& st) {
    st = RolloutState{};
    st.pos = scene.player.pos;
    st.vel = scene.player.vel;
    if (scene.hasTwin) {
        st.twinPos = scene.twin.pos;
        st.twinVel = scene.twin.vel;
    }

    Vec2 path[BulletTrack::kMaxPts];
    Vec2 vels[BulletTrack::kMaxPts];
    Vec2 twinPath[BulletTrack::kMaxPts];
    Vec2 twinVels[BulletTrack::kMaxPts];
    bool movedAt[BulletTrack::kMaxPts];

    path[0] = st.pos;
    vels[0] = st.vel;
    movedAt[0] = false;
    float pMinX = st.pos.x, pMaxX = st.pos.x, pMinY = st.pos.y, pMaxY = st.pos.y;
    ChunkBox pChunks[8]{};
    for (int blk = 0; blk < pt.numChunks; ++blk) pChunks[blk].reset();
    pChunks[0].expand(st.pos.x, st.pos.y);

    float tMinX = 0.0f, tMaxX = 0.0f, tMinY = 0.0f, tMaxY = 0.0f;
    ChunkBox tChunks[8]{};
    if (scene.hasTwin) {
        twinPath[0] = st.twinPos;
        twinVels[0] = st.twinVel;
        tMinX = tMaxX = st.twinPos.x;
        tMinY = tMaxY = st.twinPos.y;
        for (int blk = 0; blk < pt.numChunks; ++blk) tChunks[blk].reset();
        tChunks[0].expand(st.twinPos.x, st.twinPos.y);
    }

    int qSteps = std::min(maxK, scene.queueDelay30 * 2 + kin.extraDelay60);
    bool qZero = (rawDir <= 0 || rawDir >= 9);
    Vec2 qAccel = candVec(rawDir) * kin.accel;
    Vec2 tQAccel = candVec(rawDir) * twinKin.accel;
    bool dZero = (dir <= 0 || dir >= 9);
    Vec2 dVec = candVec(dir);
    Vec2 dAccel = dVec * kin.accel;
    Vec2 tDAccel = dVec * twinKin.accel;

    for (int k = 1; k <= maxK; ++k) {
        bool steered = (k > qSteps);
        bool stepMoved = false;
        stepPlayer60Fast(scene.grid, gf, scene.player.size, scene.player.canFly,
                         originUnsafe, steered ? dZero : qZero, steered ? dAccel : qAccel,
                         kin, st.pos, st.vel, stepMoved);
        if (steered && stepMoved) st.moved = true;
        path[k] = st.pos;
        vels[k] = st.vel;
        movedAt[k] = st.moved;
        pMinX = std::min(pMinX, st.pos.x); pMaxX = std::max(pMaxX, st.pos.x);
        pMinY = std::min(pMinY, st.pos.y); pMaxY = std::max(pMaxY, st.pos.y);
        int blk = k >> 3;
        pChunks[blk].expand(path[k - 1].x, path[k - 1].y);
        pChunks[blk].expand(st.pos.x, st.pos.y);

        if (scene.hasTwin) {
            bool twinMoved = false;
            stepPlayer60Fast(scene.grid, gf, scene.twin.size, scene.twin.canFly,
                             twinOriginUnsafe, steered ? dZero : qZero, steered ? tDAccel : tQAccel,
                             twinKin, st.twinPos, st.twinVel, twinMoved);
            twinPath[k] = st.twinPos;
            twinVels[k] = st.twinVel;
            tMinX = std::min(tMinX, st.twinPos.x); tMaxX = std::max(tMaxX, st.twinPos.x);
            tMinY = std::min(tMinY, st.twinPos.y); tMaxY = std::max(tMaxY, st.twinPos.y);
            tChunks[blk].expand(twinPath[k - 1].x, twinPath[k - 1].y);
            tChunks[blk].expand(st.twinPos.x, st.twinPos.y);
        }
    }

    // If queueDelay consumed the whole horizon, still test 2 post-queue ticks so blockedMask is physical!
    if (qSteps >= maxK && dir > 0) {
        Vec2 probePos = st.pos, probeVel = st.vel;
        bool probeMoved = false;
        for (int p = 0; p < 2; ++p) {
            stepPlayer60Fast(scene.grid, gf, scene.player.size, scene.player.canFly,
                             originUnsafe, dZero, dAccel, kin, probePos, probeVel, probeMoved);
        }
        st.moved = probeMoved;
    }

    float stepHardMax[BulletTrack::kMaxPts]{};
    float stepWarnMax[BulletTrack::kMaxPts]{};
    float stepMinGap[BulletTrack::kMaxPts];
    uint8_t stepAutoAvoid[BulletTrack::kMaxPts]{};
    for (int k = 0; k < maxK; ++k) stepMinGap[k] = 4.0f;
    stepMinGap[maxK] = 24.0f;

    // Non-terminal straight clearance is only compared against < 4.0f (needTurnSearch); k == maxK keeps 24.0f for endGap.
    evalBodyRangeBlocked(scene, pt, path, pChunks, pMinX, pMaxX, pMinY, pMaxY,
                         scene.player.size, scene.player.canFly, 0, maxK, maxK, 4.0f,
                         stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
    if (scene.hasTwin) {
        evalBodyRangeBlocked(scene, pt, twinPath, tChunks, tMinX, tMaxX, tMinY, tMaxY,
                             scene.twin.size, scene.twin.canFly, 0, maxK, maxK, 4.0f,
                             stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
    }

    if (!recordSnaps) {
        accumulateRolloutSteps(0, maxK, maxK, stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid, st);
        return;
    }

    int curStart = 0;
    for (int ci = 0; ci < 3; ++ci) {
        int cEnd = std::min(maxK, pivots[ci]);
        if (cEnd >= curStart) {
            accumulateRolloutSteps(curStart, cEnd, maxK, stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid, st);
            curStart = cEnd + 1;
        }
        st.snaps[ci] = makeSnap(st, path[cEnd], vels[cEnd], twinPath[cEnd], twinVels[cEnd], movedAt[cEnd]);
    }
    if (curStart <= maxK) {
        accumulateRolloutSteps(curStart, maxK, maxK, stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid, st);
    }
}

inline bool continueAfterPivotSnap(const ThreatScene& scene, PrecompThreats& pt,
                                   const GridFastInfo& gf,
                                   const RolloutSnapshot& sn, int pivotK,
                                   int dir2,
                                   bool originUnsafe, bool twinOriginUnsafe,
                                   const PlayerKinematics& kin, const PlayerKinematics& twinKin,
                                   int maxK, int abortFirstHardLe, int abortLastHardGt,
                                   bool abortAnyWarn, int maxEndDepthBucket,
                                   float maxTieHardPen,
                                   RolloutState& st, TurnPathBuffer& buf) {
    st.initFromSnap(sn);

    int clampedPivot = std::min(maxK, pivotK);
    if (clampedPivot >= maxK) return true;

    buf.path[clampedPivot] = st.pos;
    if (scene.hasTwin) buf.twinPath[clampedPivot] = st.twinPos;

    int k0 = clampedPivot + 1;
    bool dZero = (dir2 <= 0 || dir2 >= 9);
    Vec2 dVec = candVec(dir2);
    Vec2 dAccel = dVec * kin.accel;
    Vec2 tDAccel = dVec * twinKin.accel;

    float stepHardMax[BulletTrack::kMaxPts];
    float stepWarnMax[BulletTrack::kMaxPts];
    float stepMinGap[BulletTrack::kMaxPts];
    uint8_t stepAutoAvoid[BulletTrack::kMaxPts];

    auto initRange = [&](int a, int b) {
        for (int k = a; k <= b; ++k) {
            stepHardMax[k] = 0.0f;
            stepWarnMax[k] = 0.0f;
            stepMinGap[k] = (k == maxK) ? 24.0f : 0.0f;
            stepAutoAvoid[k] = 0;
        }
    };

    auto buildChunks = [&](int fromK, const Vec2* pathArr, ChunkBox chunks[8],
                           float& minX, float& maxX, float& minY, float& maxY) {
        minX = maxX = pathArr[fromK - 1].x;
        minY = maxY = pathArr[fromK - 1].y;
        for (int blk = 0; blk < pt.numChunks; ++blk) chunks[blk].reset();
        for (int k = fromK; k <= maxK; ++k) {
            minX = std::min(minX, pathArr[k].x); maxX = std::max(maxX, pathArr[k].x);
            minY = std::min(minY, pathArr[k].y); maxY = std::max(maxY, pathArr[k].y);
            int blk = k >> 3;
            chunks[blk].expand(pathArr[k - 1].x, pathArr[k - 1].y);
            chunks[blk].expand(pathArr[k].x, pathArr[k].y);
        }
    };

    auto computeInteriorSafe = [&]() -> bool {
        if (!gf.fastOpen || originUnsafe || scene.hasTwin) return false;
        float vMax = 4.2f * scene.player.moveSpeed;
        float maxVx = dZero ? std::abs(st.vel.x) : std::max(std::abs(st.vel.x), std::abs(dVec.x) * vMax);
        float maxVy = dZero ? std::abs(st.vel.y) : std::max(std::abs(st.vel.y), std::abs(dVec.y) * vMax);
        float nSteps = static_cast<float>(maxK - k0 + 1);
        float pr = std::max(2.0f, scene.player.size - 1.0f);
        return (maxVx * maxVx + maxVy * maxVy <= 36.0f) &&
               (st.pos.x - nSteps * maxVx - pr >= scene.grid.topLeft.x) &&
               (st.pos.x + nSteps * maxVx + pr <= scene.grid.bottomRight.x) &&
               (st.pos.y - nSteps * maxVy - pr >= scene.grid.topLeft.y) &&
               (st.pos.y + nSteps * maxVy + pr <= scene.grid.bottomRight.y);
    };

    auto simKinRange = [&](int a, int b, bool interiorSafe) {
        if (a > b) return;
        if (interiorSafe) {
            float f = dZero ? kin.fIdle : kin.fDrive;
            float ax = dZero ? 0.0f : dAccel.x;
            float ay = dZero ? 0.0f : dAccel.y;
            float px = st.pos.x, py = st.pos.y, vx = st.vel.x, vy = st.vel.y;
            bool mv = st.moved;
            for (int k = a; k <= b; ++k) {
                vx = vx * f + ax;
                vy = vy * f + ay;
                if (vx * vx + vy * vy >= 1e-8f) {
                    px += vx;
                    py += vy;
                    mv = true;
                }
                buf.path[k] = {px, py};
            }
            st.pos = {px, py};
            st.vel = {vx, vy};
            st.moved = mv;
        } else {
            for (int k = a; k <= b; ++k) {
                bool stepMoved = false;
                stepPlayer60Fast(scene.grid, gf, scene.player.size, scene.player.canFly,
                                 originUnsafe, dZero, dAccel, kin, st.pos, st.vel, stepMoved);
                if (stepMoved) st.moved = true;
                buf.path[k] = st.pos;
                if (scene.hasTwin) {
                    bool twinMoved = false;
                    stepPlayer60Fast(scene.grid, gf, scene.twin.size, scene.twin.canFly,
                                     twinOriginUnsafe, dZero, tDAccel, twinKin, st.twinPos, st.twinVel, twinMoved);
                    buf.twinPath[k] = st.twinPos;
                }
            }
        }
    };

    // Regime C1 (!inside && !abortAnyWarn && abortFirstHardLe >= 0): ultra-fast hard-only zero-sqrt interleaved probe
    if (!abortAnyWarn && abortFirstHardLe >= 0) {
        bool interiorSafe = computeInteriorSafe();
        int kCheckEnd = std::min(maxK, abortFirstHardLe);
        int kHardLo = std::max(k0, pt.minHardK);
        int kHardHi = std::min(kCheckEnd, pt.maxHardK);
        if (kHardLo <= kHardHi) {
            simKinRange(k0, kHardLo - 1, interiorSafe);
            if (interiorSafe) {
                float f = dZero ? kin.fIdle : kin.fDrive;
                float ax = dZero ? 0.0f : dAccel.x;
                float ay = dZero ? 0.0f : dAccel.y;
                float px = st.pos.x, py = st.pos.y, vx = st.vel.x, vy = st.vel.y;
                bool mv = st.moved;
                for (int k = kHardLo; k <= kHardHi; ++k) {
                    vx = vx * f + ax;
                    vy = vy * f + ay;
                    if (vx * vx + vy * vy >= 1e-8f) {
                        px += vx;
                        py += vy;
                        mv = true;
                    }
                    buf.path[k] = {px, py};
                    if (hitsHardAtStep(scene, pt, buf.path[k - 1], buf.path[k], scene.player.size, scene.player.canFly, k)) {
                        st.pos = {px, py}; st.vel = {vx, vy}; st.moved = mv;
                        st.hasHard = true;
                        st.firstHardK = std::min(st.firstHardK, k);
                        st.lastHardK = std::max(st.lastHardK, k);
                        return false;
                    }
                }
                st.pos = {px, py};
                st.vel = {vx, vy};
                st.moved = mv;
            } else {
                for (int k = kHardLo; k <= kHardHi; ++k) {
                    bool stepMoved = false;
                    stepPlayer60Fast(scene.grid, gf, scene.player.size, scene.player.canFly,
                                     originUnsafe, dZero, dAccel, kin, st.pos, st.vel, stepMoved);
                    if (stepMoved) st.moved = true;
                    buf.path[k] = st.pos;
                    if (hitsHardAtStep(scene, pt, buf.path[k - 1], st.pos, scene.player.size, scene.player.canFly, k)) {
                        st.hasHard = true;
                        st.firstHardK = std::min(st.firstHardK, k);
                        st.lastHardK = std::max(st.lastHardK, k);
                        return false;
                    }
                    if (scene.hasTwin) {
                        bool twinMoved = false;
                        stepPlayer60Fast(scene.grid, gf, scene.twin.size, scene.twin.canFly,
                                         twinOriginUnsafe, dZero, tDAccel, twinKin, st.twinPos, st.twinVel, twinMoved);
                        buf.twinPath[k] = st.twinPos;
                        if (hitsHardAtStep(scene, pt, buf.twinPath[k - 1], st.twinPos, scene.twin.size, scene.twin.canFly, k)) {
                            st.hasHard = true;
                            st.firstHardK = std::min(st.firstHardK, k);
                            st.lastHardK = std::max(st.lastHardK, k);
                            return false;
                        }
                    }
                }
            }
            simKinRange(kHardHi + 1, maxK, interiorSafe);
        } else {
            simKinRange(k0, maxK, interiorSafe);
        }
        // Exact branch-and-bound on the survival-tie tick (tieK = abortFirstHardLe + 1):
        // if penetration at tieK alone exceeds maxTieHardPen, sub > targetScore's sub, so prune before warning/BFS eval!
        int tieK = abortFirstHardLe + 1;
        if (maxTieHardPen > 0.0f && tieK >= std::max(k0, pt.minHardK) && tieK <= std::min(maxK, pt.maxHardK)) {
            if (hitsHardAtStep(scene, pt, buf.path[tieK - 1], buf.path[tieK],
                               scene.player.size, scene.player.canFly, tieK, maxTieHardPen) ||
                (scene.hasTwin && hitsHardAtStep(scene, pt, buf.twinPath[tieK - 1], buf.twinPath[tieK],
                                                 scene.twin.size, scene.twin.canFly, tieK, maxTieHardPen))) {
                st.hasHard = true;
                st.firstHardK = std::min(st.firstHardK, tieK);
                st.lastHardK = std::max(st.lastHardK, tieK);
                return false;
            }
        }
        initRange(k0, maxK);
        float pMinX, pMaxX, pMinY, pMaxY, tMinX, tMaxX, tMinY, tMaxY;
        ChunkBox pChunks[8], tChunks[8];
        buildChunks(k0, buf.path, pChunks, pMinX, pMaxX, pMinY, pMaxY);
        evalBodyRangeBlocked(scene, pt, buf.path, pChunks, pMinX, pMaxX, pMinY, pMaxY,
                             scene.player.size, scene.player.canFly, k0, maxK, maxK, 0.0f,
                             stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
        if (scene.hasTwin) {
            buildChunks(k0, buf.twinPath, tChunks, tMinX, tMaxX, tMinY, tMaxY);
            evalBodyRangeBlocked(scene, pt, buf.twinPath, tChunks, tMinX, tMaxX, tMinY, tMaxY,
                                 scene.twin.size, scene.twin.canFly, k0, maxK, maxK, 0.0f,
                                 stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
        }
        accumulateRolloutSteps(k0, maxK, maxK, stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid, st);
        return true;
    }

    // Regime C2 (abortAnyWarn): interleave kinematics & step-major check across k0..maxK
    if (abortAnyWarn) {
        initRange(k0, maxK);
        for (int k = k0; k <= maxK; ++k) {
            bool stepMoved = false;
            stepPlayer60Fast(scene.grid, gf, scene.player.size, scene.player.canFly,
                             originUnsafe, dZero, dAccel, kin, st.pos, st.vel, stepMoved);
            if (stepMoved) st.moved = true;
            buf.path[k] = st.pos;

            if (evalBodyAtStep(scene, pt, buf.path[k - 1], st.pos, scene.player.size, scene.player.canFly,
                               k, maxK, true, stepHardMax[k], stepWarnMax[k], stepMinGap[k],
                               st, true, true)) {
                return false;
            }
            if (scene.hasTwin) {
                bool twinMoved = false;
                stepPlayer60Fast(scene.grid, gf, scene.twin.size, scene.twin.canFly,
                                 twinOriginUnsafe, dZero, tDAccel, twinKin, st.twinPos, st.twinVel, twinMoved);
                buf.twinPath[k] = st.twinPos;
                if (evalBodyAtStep(scene, pt, buf.twinPath[k - 1], st.twinPos, scene.twin.size, scene.twin.canFly,
                                   k, maxK, true, stepHardMax[k], stepWarnMax[k], stepMinGap[k],
                                   st, true, true)) {
                    return false;
                }
            }
        }
        accumulateRolloutSteps(k0, maxK, maxK, stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid, st);
        return true;
    }

    // Regimes A / B / D: simulate kinematics k0..maxK (branchless fast interior loop when wall-free)
    simKinRange(k0, maxK, computeInteriorSafe());

    // Regime A (inside && abortLastHardGt >= 0): hard-only zero-sqrt tail check maxHardK down to abortLastHardGt + 1
    if (abortLastHardGt >= 0) {
        int tailLo = std::max(k0, std::max(abortLastHardGt + 1, pt.minHardK));
        int tailHi = std::min(maxK, pt.maxHardK);
        for (int k = tailHi; k >= tailLo; --k) {
            if (hitsHardAtStep(scene, pt, buf.path[k - 1], buf.path[k], scene.player.size, scene.player.canFly, k)) {
                st.hasHard = true;
                st.lastHardK = std::max(st.lastHardK, k);
                st.firstHardK = std::min(st.firstHardK, k);
                return false;
            }
            if (scene.hasTwin) {
                if (hitsHardAtStep(scene, pt, buf.twinPath[k - 1], buf.twinPath[k], scene.twin.size, scene.twin.canFly, k)) {
                    st.hasHard = true;
                    st.lastHardK = std::max(st.lastHardK, k);
                    st.firstHardK = std::min(st.firstHardK, k);
                    return false;
                }
            }
        }
        initRange(k0, maxK);
        float pMinX, pMaxX, pMinY, pMaxY, tMinX, tMaxX, tMinY, tMaxY;
        ChunkBox pChunks[8], tChunks[8];
        buildChunks(k0, buf.path, pChunks, pMinX, pMaxX, pMinY, pMaxY);
        evalBodyRangeBlocked(scene, pt, buf.path, pChunks, pMinX, pMaxX, pMinY, pMaxY,
                             scene.player.size, scene.player.canFly, k0, maxK, maxK, 0.0f,
                             stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
        if (scene.hasTwin) {
            buildChunks(k0, buf.twinPath, tChunks, tMinX, tMaxX, tMinY, tMaxY);
            evalBodyRangeBlocked(scene, pt, buf.twinPath, tChunks, tMinX, tMaxX, tMinY, tMaxY,
                                 scene.twin.size, scene.twin.canFly, k0, maxK, maxK, 0.0f,
                                 stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
        }
        accumulateRolloutSteps(k0, maxK, maxK, stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid, st);
        return true;
    }

    initRange(k0, maxK);
    float pMinX, pMaxX, pMinY, pMaxY, tMinX, tMaxX, tMinY, tMaxY;
    ChunkBox pChunks[8], tChunks[8];
    buildChunks(k0, buf.path, pChunks, pMinX, pMaxX, pMinY, pMaxY);
    if (scene.hasTwin) buildChunks(k0, buf.twinPath, tChunks, tMinX, tMaxX, tMinY, tMaxY);

    // Regime B (inside && maxEndDepthBucket >= 0): test terminal step k == maxK first!
    if (maxEndDepthBucket >= 0) {
        evalBodyAtStep(scene, pt, buf.path[maxK - 1], buf.path[maxK], scene.player.size, scene.player.canFly,
                       maxK, maxK, true, stepHardMax[maxK], stepWarnMax[maxK], stepMinGap[maxK],
                       st, false, false);
        if (scene.hasTwin) {
            evalBodyAtStep(scene, pt, buf.twinPath[maxK - 1], buf.twinPath[maxK], scene.twin.size, scene.twin.canFly,
                           maxK, maxK, true, stepHardMax[maxK], stepWarnMax[maxK], stepMinGap[maxK],
                           st, false, false);
        }
        if (stepHardMax[maxK] > 0.0f &&
            std::min(999, static_cast<int>(std::floor(stepHardMax[maxK] * 4.0f))) > maxEndDepthBucket) {
            st.endHardPen = stepHardMax[maxK];
            st.hasHard = true;
            st.lastHardK = std::max(st.lastHardK, maxK);
            st.firstHardK = std::min(st.firstHardK, maxK);
            return false;
        }
        if (k0 <= maxK - 1) {
            evalBodyRangeBlocked(scene, pt, buf.path, pChunks, pMinX, pMaxX, pMinY, pMaxY,
                                 scene.player.size, scene.player.canFly, k0, maxK - 1, maxK, 0.0f,
                                 stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
            if (scene.hasTwin) {
                evalBodyRangeBlocked(scene, pt, buf.twinPath, tChunks, tMinX, tMaxX, tMinY, tMaxY,
                                     scene.twin.size, scene.twin.canFly, k0, maxK - 1, maxK, 0.0f,
                                     stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
            }
        }
        accumulateRolloutSteps(k0, maxK, maxK, stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid, st);
        return true;
    }

    // Regime D: full range
    evalBodyRangeBlocked(scene, pt, buf.path, pChunks, pMinX, pMaxX, pMinY, pMaxY,
                         scene.player.size, scene.player.canFly, k0, maxK, maxK, 0.0f,
                         stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
    if (scene.hasTwin) {
        evalBodyRangeBlocked(scene, pt, buf.twinPath, tChunks, tMinX, tMaxX, tMinY, tMaxY,
                             scene.twin.size, scene.twin.canFly, k0, maxK, maxK, 0.0f,
                             stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid);
    }
    accumulateRolloutSteps(k0, maxK, maxK, stepHardMax, stepWarnMax, stepMinGap, stepAutoAvoid, st);
    return true;
}

inline bool hasAnyAutoAvoidCell(const RoomGrid& grid) {
    for (int i = 0; i < grid.cellCount; ++i) {
        if ((grid.cells[i] & RoomGrid::kAutoAvoid) != 0) return true;
    }
    return false;
}

} // namespace planner_detail

// Plan 60Hz multi-step straight + 2-stage turning trajectories on `scene`.
// Returns -1 (passthrough) if current/manual trajectory is completely safe, or 0..8 world direction.
inline PlanResult solveNativePlan(const ThreatScene& scene, int rawWorldDir,
                                  int prevChosenWorld, bool allowPickups) {
    PlanResult res{};
    if (!scene.valid) return res;
    res.valid = true;

    const PlayerState& pl = scene.player;
    const RoomGrid& grid = scene.grid;
    int maxK = std::min(scene.steps60, BulletTrack::kMaxPts - 1);

    auto kinFast = planner_detail::PlayerKinematics::fast(pl, scene.extAccel);
    auto kinSlow = planner_detail::PlayerKinematics::slow(pl, scene.extAccel);
    auto twinFast = scene.hasTwin ? planner_detail::PlayerKinematics::fast(scene.twin, scene.extAccel) : kinFast;
    auto twinSlow = scene.hasTwin ? planner_detail::PlayerKinematics::slow(scene.twin, scene.extAccel) : kinSlow;

    planner_detail::GridFastInfo gf;
    gf.init(grid);

    bool originUnsafe = !gf.footprintSafe(grid, pl.pos.x, pl.pos.y, pl.size, pl.canFly);
    bool twinOriginUnsafe = scene.hasTwin &&
                            !gf.footprintSafe(grid, scene.twin.pos.x, scene.twin.pos.y, scene.twin.size, scene.twin.canFly);
    bool hasAutoAvoid = planner_detail::hasAnyAutoAvoidCell(grid);

    // Fast path: empty threat scene checks physical terrain blocking (and quick autoAvoid probe in AUTO mode).
    if (scene.bullets.empty() && scene.discs.empty() && scene.lasers.empty()) {
        int qSteps = scene.queueDelay30 * 2;
        bool qZero = (rawWorldDir <= 0 || rawWorldDir >= 9);
        Vec2 qAccelFast = candVec(rawWorldDir) * kinFast.accel;
        if (allowPickups || !hasAutoAvoid) {
            int probeK = std::min(BulletTrack::kMaxPts - 1, std::max(maxK, qSteps + 6));
            for (int d = 1; d < 9; ++d) {
                Vec2 pos = pl.pos, vel = pl.vel;
                bool moved = false;
                Vec2 dAccel = candVec(d) * kinFast.accel;
                for (int k = 1; k <= probeK; ++k) {
                    bool steered = (k > qSteps);
                    bool stepMoved = false;
                    planner_detail::stepPlayer60Fast(grid, gf, pl.size, pl.canFly, originUnsafe,
                                                     steered ? false : qZero, steered ? dAccel : qAccelFast,
                                                     kinFast, pos, vel, stepMoved);
                    if (steered && stepMoved) moved = true;
                }
                if (!moved) res.blockedMask |= (1 << d);
            }
            res.danger = false;
            res.bestDir = -1;
            return res;
        }
        // AUTO mode with pedestals/mimics but zero combat threats (e.g. Library Room 12.4):
        // check whether any candidate direction actually touches a kAutoAvoid cell before allocating BFS/rollouts.
        int qStepsSlow = std::min(maxK, qSteps + kinSlow.extraDelay60);
        int qStepsFastClamped = std::min(maxK, qSteps);
        Vec2 qAccelSlow = candVec(rawWorldDir) * kinSlow.accel;
        Vec2 tQAccelFast = candVec(rawWorldDir) * twinFast.accel;
        Vec2 tQAccelSlow = candVec(rawWorldDir) * twinSlow.accel;
        bool anyAutoCrossed = false;
        int fastBlocked = 0;
        for (int d = 0; d < 9 && !anyAutoCrossed; ++d) {
            bool dZero = (d == 0);
            Vec2 dVec = candVec(d);
            Vec2 dAF = dVec * kinFast.accel, dAS = dVec * kinSlow.accel;
            Vec2 pF = pl.pos, vF = pl.vel, pS = pl.pos, vS = pl.vel;
            bool mF = false, mS = false;
            Vec2 tpF = scene.twin.pos, tvF = scene.twin.vel, tpS = scene.twin.pos, tvS = scene.twin.vel;
            bool tmF = false, tmS = false;
            for (int k = 1; k <= maxK; ++k) {
                bool stF = (k > qStepsFastClamped), stS = (k > qStepsSlow);
                bool smF = false, smS = false;
                planner_detail::stepPlayer60Fast(grid, gf, pl.size, pl.canFly, originUnsafe,
                                                 stF ? dZero : qZero, stF ? dAF : qAccelFast, kinFast, pF, vF, smF);
                planner_detail::stepPlayer60Fast(grid, gf, pl.size, pl.canFly, originUnsafe,
                                                 stS ? dZero : qZero, stS ? dAS : qAccelSlow, kinSlow, pS, vS, smS);
                if (stF && smF) mF = true;
                if (stS && smS) mS = true;
                if (grid.cellAutoAvoid(grid.indexAt(pF.x, pF.y)) ||
                    grid.cellAutoAvoid(grid.indexAt(pS.x, pS.y))) {
                    anyAutoCrossed = true;
                    break;
                }
                if (scene.hasTwin) {
                    planner_detail::stepPlayer60Fast(grid, gf, scene.twin.size, scene.twin.canFly, twinOriginUnsafe,
                                                     stF ? dZero : qZero, stF ? (dVec * twinFast.accel) : tQAccelFast,
                                                     twinFast, tpF, tvF, tmF);
                    planner_detail::stepPlayer60Fast(grid, gf, scene.twin.size, scene.twin.canFly, twinOriginUnsafe,
                                                     stS ? dZero : qZero, stS ? (dVec * twinSlow.accel) : tQAccelSlow,
                                                     twinSlow, tpS, tvS, tmS);
                    if (grid.cellAutoAvoid(grid.indexAt(tpF.x, tpF.y)) ||
                        grid.cellAutoAvoid(grid.indexAt(tpS.x, tpS.y))) {
                        anyAutoCrossed = true;
                        break;
                    }
                }
            }
            if (!anyAutoCrossed && d > 0) {
                if (qStepsFastClamped >= maxK) {
                    Vec2 pp = pF, pv = vF; bool pm = false;
                    for (int p = 0; p < 2; ++p)
                        planner_detail::stepPlayer60Fast(grid, gf, pl.size, pl.canFly, originUnsafe, dZero, dAF, kinFast, pp, pv, pm);
                    mF = pm;
                }
                if (qStepsSlow >= maxK) {
                    Vec2 pp = pS, pv = vS; bool pm = false;
                    for (int p = 0; p < 2; ++p)
                        planner_detail::stepPlayer60Fast(grid, gf, pl.size, pl.canFly, originUnsafe, dZero, dAS, kinSlow, pp, pv, pm);
                    mS = pm;
                }
                if (!mF && !mS) fastBlocked |= (1 << d);
            }
        }
        if (!anyAutoCrossed) {
            res.blockedMask = fastBlocked;
            res.danger = false;
            res.bestDir = -1;
            return res;
        }
    }

    planner_detail::PrecompThreats pt;
    pt.init(scene, maxK, allowPickups, hasAutoAvoid);
    planner_detail::SpaceBfsCache bfsCache;
    bfsCache.init(scene);

    // Dynamic post-queue pivot checkpoints (+2, +4, +6 60Hz ticks AFTER queueDelay + extraDelay60)
    int qBaseFast = scene.queueDelay30 * 2 + kinFast.extraDelay60;
    int qBaseSlow = scene.queueDelay30 * 2 + kinSlow.extraDelay60;
    const int pivotsFast[3] = {qBaseFast + 2, qBaseFast + 4, qBaseFast + 6};
    const int pivotsSlow[3] = {qBaseSlow + 2, qBaseSlow + 4, qBaseSlow + 6};
    bool canRecordSnaps = (pivotsFast[0] < maxK - 1);

    // 1. Evaluate all 9 straight candidates
    std::array<planner_detail::RolloutState, 9> sFast{}, sSlow{};
    bool inside = false;
    bool anyDanger = false;

    for (int d = 0; d < 9; ++d) {
        planner_detail::simulateStraight(
            scene, pt, gf, d, rawWorldDir, originUnsafe, twinOriginUnsafe,
            kinFast, twinFast, maxK, pivotsFast, canRecordSnaps, sFast[d]);
        planner_detail::simulateStraight(
            scene, pt, gf, d, rawWorldDir, originUnsafe, twinOriginUnsafe,
            kinSlow, twinSlow, maxK, pivotsSlow, canRecordSnaps, sSlow[d]);
        if (d > 0 && !sFast[d].moved && !sSlow[d].moved) {
            res.blockedMask |= (1 << d);
        }
        if (sFast[d].hasHard || sSlow[d].hasHard || sFast[d].hasWarn || sSlow[d].hasWarn ||
            sFast[d].crossedAutoAvoid || sSlow[d].crossedAutoAvoid) {
            anyDanger = true;
        }
        if (sFast[d].firstHardK == 0 || sSlow[d].firstHardK == 0) {
            inside = true;
        }
    }

    res.inside = inside;
    res.danger = anyDanger;

    if (!anyDanger) {
        for (int d = 0; d < 9; ++d) {
            res.straightScores[d] = 0.0;
            res.scores[d] = 0.0;
        }
        res.bestDir = -1;
        return res;
    }

    double bestStraightScore = 1e30;
    float bestSafeClearance = 0.0f;
    for (int d = 0; d < 9; ++d) {
        double s = planner_detail::computeRolloutScore(
            scene, sFast[d], sSlow[d], inside, maxK, d, prevChosenWorld, rawWorldDir, false, bfsCache);
        res.straightScores[d] = s;
        res.scores[d] = s;
        if ((d == 0 || (res.blockedMask & (1 << d)) == 0) && s < bestStraightScore) {
            bestStraightScore = s;
            bestSafeClearance = std::min(sFast[d].minClearance, sSlow[d].minClearance);
        }
    }

    // Check if manual input (rawWorldDir, 0 = idle) is already completely straight-safe
    int checkManual = (rawWorldDir >= 0 && rawWorldDir < 9) ? rawWorldDir : 0;
    if ((checkManual == 0 || (res.blockedMask & (1 << checkManual)) == 0) &&
        res.straightScores[checkManual] <= 0.0) {
        res.bestDir = -1; // manual input is straight-safe: passthrough!
        return res;
    }

    // 2. Run 2-stage turning trajectory search if straight routes hit hard/AUTO-avoid hazards or graze closely.
    // Pure soft-warning-only scenes (e.g. standing on a bomb whose straight escape already clears the blast)
    // do not need a 432-rollout turn search.
    static constexpr double kScale = PlanResult::kScale;
    static constexpr double kHard  = PlanResult::kHard;
    static constexpr double kAutoAvoidTier = 600000.0 * kScale;
    bool needTurnSearch = (bestStraightScore >= kAutoAvoidTier) ||
                          (bestStraightScore <= 0.0 && bestSafeClearance < 4.0f);

    if (needTurnSearch && canRecordSnaps) {
        double bestOverall = bestStraightScore;
        planner_detail::RolloutState fullFast{}, fullSlow{};
        planner_detail::TurnPathBuffer turnBuf;

        auto searchTurnRange = [&](int dBegin, int dEnd) {
            for (int pIdx = 0; pIdx < 3; ++pIdx) {
                int pKFast = pivotsFast[pIdx];
                int pKSlow = pivotsSlow[pIdx];
                if (pKFast >= maxK - 1) continue;
                for (int d1 = dBegin; d1 <= dEnd; ++d1) {
                    if (d1 > 0 && (res.blockedMask & (1 << d1)) != 0) continue;
                    const auto& snFast = sFast[d1].snaps[pIdx];
                    const auto& snSlow = sSlow[d1].snaps[pIdx];
                    if (d1 > 0 && !snFast.moved && !snSlow.moved) continue;

                    double hystSlack = (d1 == prevChosenWorld) ? 65536.0 : 0.0;
                    double targetScore = std::min(res.scores[d1], bestOverall + hystSlack);

                    if (targetScore < 0.0 && (snFast.hasHard || snSlow.hasHard || snFast.hasWarn || snSlow.hasWarn ||
                                              snFast.crossedAutoAvoid || snSlow.crossedAutoAvoid)) {
                        continue;
                    }

                    int cutoffK = -1;
                    int abortLastGt = -1;
                    int maxEndBucket = -1;
                    float maxTiePen = -1.0f;
                    bool abortWarn = (targetScore < 0.0);
                    auto refreshBounds = [&]() {
                        cutoffK = -1;
                        abortLastGt = -1;
                        maxEndBucket = -1;
                        maxTiePen = -1.0f;
                        abortWarn = (targetScore < 0.0);
                        if (abortWarn) {
                            cutoffK = maxK;
                        } else if (!inside) {
                            if (targetScore < kHard) {
                                cutoffK = maxK;
                            } else {
                                int64_t targetTier = static_cast<int64_t>(std::floor(targetScore / kScale));
                                int minSurv = static_cast<int>(targetTier / 1000000LL);
                                cutoffK = std::max(-1, (maxK + 1) - minSurv);
                                int64_t maxSub = targetTier % 1000000LL;
                                if (maxSub < 989999LL) {
                                    maxTiePen = static_cast<float>(maxSub + 1) / 2000.0f + 1e-4f;
                                }
                            }
                        } else if (targetScore < 2000000.0 * kScale) {
                            int bestTier = static_cast<int>(std::floor(targetScore / kScale));
                            abortLastGt = std::max(0, (bestTier - 1000000) / 10000 - 1);
                        } else {
                            int64_t bestTier = static_cast<int64_t>(std::floor(targetScore / kScale));
                            maxEndBucket = static_cast<int>((bestTier - 2000000LL) / 1000LL);
                        }
                    };
                    refreshBounds();
                    if (!inside && cutoffK >= 0 &&
                        ((snFast.hasHard && snFast.firstHardK <= cutoffK) ||
                         (snSlow.hasHard && snSlow.firstHardK <= cutoffK))) {
                        continue;
                    }
                    if (inside && abortLastGt >= 0) {
                        if (std::max(snFast.lastHardK, snSlow.lastHardK) > abortLastGt) {
                            continue;
                        }
                        // If all hard hazards have already ended by pivotK, turning afterwards cannot improve hard exit time.
                        if (pt.maxHardK >= 0 && pKFast >= pt.maxHardK && pKSlow >= pt.maxHardK) {
                            continue;
                        }
                    }

                    for (int d2 = 0; d2 < 9; ++d2) {
                        if (d2 == d1) continue;
                        if (!planner_detail::continueAfterPivotSnap(
                                scene, pt, gf, snFast, pKFast, d2,
                                originUnsafe, twinOriginUnsafe, kinFast, twinFast, maxK,
                                cutoffK, abortLastGt, abortWarn, maxEndBucket, maxTiePen, fullFast, turnBuf)) {
                            continue;
                        }
                        if (abortWarn && (fullFast.hasHard || fullFast.hasWarn || fullFast.crossedAutoAvoid)) continue;
                        if (!inside && fullFast.hasHard && cutoffK >= 0 && fullFast.firstHardK <= cutoffK) continue;
                        if (inside && abortLastGt >= 0 && fullFast.hasHard && fullFast.lastHardK > abortLastGt) continue;
                        if (inside && maxEndBucket >= 0 && fullFast.endHardPen > 0.0f &&
                            std::min(999, static_cast<int>(std::floor(fullFast.endHardPen * 4.0f))) > maxEndBucket) {
                            continue;
                        }

                        if (!planner_detail::continueAfterPivotSnap(
                                scene, pt, gf, snSlow, pKSlow, d2,
                                originUnsafe, twinOriginUnsafe, kinSlow, twinSlow, maxK,
                                cutoffK, abortLastGt, abortWarn, maxEndBucket, maxTiePen, fullSlow, turnBuf)) {
                            continue;
                        }
                        if (abortWarn && (fullSlow.hasHard || fullSlow.hasWarn || fullSlow.crossedAutoAvoid)) continue;
                        if (!inside && fullSlow.hasHard && cutoffK >= 0 && fullSlow.firstHardK <= cutoffK) continue;
                        if (inside && abortLastGt >= 0 && fullSlow.hasHard && fullSlow.lastHardK > abortLastGt) continue;
                        if (inside && maxEndBucket >= 0 && fullSlow.endHardPen > 0.0f &&
                            std::min(999, static_cast<int>(std::floor(fullSlow.endHardPen * 4.0f))) > maxEndBucket) {
                            continue;
                        }
                        if (!fullFast.moved && !fullSlow.moved && d1 > 0) continue;

                        double ts = planner_detail::computeRolloutScore(
                            scene, fullFast, fullSlow, inside, maxK, d1, prevChosenWorld, rawWorldDir, true, bfsCache);
                        if (ts < res.scores[d1]) {
                            res.scores[d1] = ts;
                            if (ts < bestOverall) bestOverall = ts;
                            if (ts < bestStraightScore) {
                                res.usedTurn = true;
                            }
                            targetScore = std::min(res.scores[d1], bestOverall + hystSlack);
                            refreshBounds();
                        }
                    }
                }
            }
        };

        // Search active moving pivots (d1=1..8) first so wait-then-move never procrastinates safe immediate escapes.
        searchTurnRange(1, 8);

        double bestMovingScore = 1e30;
        for (int d = 1; d < 9; ++d) {
            if ((res.blockedMask & (1 << d)) == 0 && res.scores[d] < bestMovingScore) {
                bestMovingScore = res.scores[d];
            }
        }
        // Only try delayed start (d1=0 -> move d2) when no immediate moving straight/turning route avoids hard collision.
        if (bestMovingScore >= kHard && bestStraightScore >= kHard) {
            searchTurnRange(0, 0);
        }
    }

    // Pick lowest score unblocked direction; retain prevChosenWorld only within 64 space units in exact same integer tier
    double bestScore = 1e30;
    int bestDir = -1;
    for (int d = 0; d < 9; ++d) {
        if (d > 0 && (res.blockedMask & (1 << d)) != 0) continue;
        if (res.scores[d] < bestScore) {
            bestScore = res.scores[d];
            bestDir = d;
        }
    }
    if (prevChosenWorld >= 0 && prevChosenWorld < 9 &&
        (prevChosenWorld == 0 || (res.blockedMask & (1 << prevChosenWorld)) == 0)) {
        double pScore = res.scores[prevChosenWorld];
        double diff = pScore - bestScore;
        if (diff > 0.0 && diff <= 64.0 * 1024.0 &&
            std::floor(pScore / kScale) == std::floor(bestScore / kScale)) {
            bestDir = prevChosenWorld;
        }
    }

    res.bestDir = (bestDir == checkManual) ? -1 : bestDir;
    return res;
}

} // namespace iad
