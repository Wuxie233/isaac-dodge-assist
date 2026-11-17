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

    static PlayerKinematics fast(const PlayerState& pl) {
        PlayerKinematics k{};
        k.fDrive = pl.slippery ? 0.980f : 0.874f;
        k.fIdle  = pl.slippery ? 0.980f : 0.880f;
        k.accel  = 4.2f * pl.moveSpeed * (1.0f - k.fDrive);
        k.extraDelay60 = 0;
        return k;
    }

    static PlayerKinematics slow(const PlayerState& pl) {
        PlayerKinematics k{};
        k.fDrive = pl.slippery ? 0.987f : 0.894f;
        k.fIdle  = pl.slippery ? 0.987f : 0.895f;
        k.accel  = (4.2f * 0.97f) * pl.moveSpeed * (1.0f - k.fDrive);
        k.extraDelay60 = 2;
        return k;
    }
};

inline float pointSegmentDistSq(float px, float py, float ax, float ay, float bx, float by) {
    float dx = bx - ax, dy = by - ay;
    float vx = px - ax, vy = py - ay;
    float lenSq = dx * dx + dy * dy;
    float u = (lenSq > 1e-6f) ? std::max(0.0f, std::min(1.0f, (vx * dx + vy * dy) / lenSq)) : 0.0f;
    float rx = vx - dx * u, ry = vy - dy * u;
    return rx * rx + ry * ry;
}

inline float segmentSegmentDistSq(float ax, float ay, float bx, float by,
                                  float cx, float cy, float dx, float dy) {
    float abx = bx - ax, aby = by - ay;
    float cdx = dx - cx, cdy = dy - cy;
    float denom = abx * cdy - aby * cdx;
    if (std::abs(denom) > 1e-6f) {
        float x = cx - ax, y = cy - ay;
        float t = (x * cdy - y * cdx) / denom;
        float u = (x * aby - y * abx) / denom;
        if (t >= 0.0f && t <= 1.0f && u >= 0.0f && u <= 1.0f) return 0.0f;
    }
    float d1 = pointSegmentDistSq(ax, ay, cx, cy, dx, dy);
    float d2 = pointSegmentDistSq(bx, by, cx, cy, dx, dy);
    float d3 = pointSegmentDistSq(cx, cy, ax, ay, bx, by);
    float d4 = pointSegmentDistSq(dx, dy, ax, ay, bx, by);
    return std::min(std::min(d1, d2), std::min(d3, d4));
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
    float u = (lenSq > 1e-6f) ? std::max(0.0f, std::min(1.0f, -(rx0 * rvx + ry0 * rvy) / lenSq)) : 0.0f;
    float cx = rx0 + rvx * u, cy = ry0 + rvy * u;
    float distSq = cx * cx + cy * cy;
    if (distSq >= bound * bound) return -24.0f;
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

struct PrecompLaserStep {
    float t0 = 0.0f, t1 = 0.0f;
    float cosA = 1.0f, sinA = 0.0f, rotMargin = 0.0f;
    Vec2 segA{}, segB{}; // pre-rotated world segment when twoPts == true
    float sMinX = 0.0f, sMaxX = 0.0f, sMinY = 0.0f, sMaxY = 0.0f;
    bool twoPts = false;
    bool midZero = true;
    bool active = false;
};

struct PrecompLaser {
    float minX = 0.0f, maxX = 0.0f, minY = 0.0f, maxY = 0.0f;
    PrecompLaserStep steps[BulletTrack::kMaxPts]{};
};

inline void prepareLasers(const ThreatScene& scene, int maxK, std::vector<PrecompLaser>& out) {
    out.resize(scene.lasers.size());
    float ep = scene.entityPhase;
    float maxT = static_cast<float>(maxK) * 0.5f + ep;
    for (size_t i = 0; i < scene.lasers.size(); ++i) {
        const LaserHazard& l = scene.lasers[i];
        PrecompLaser& p = out[i];
        float pad = l.width + 2.0f;
        float vx0 = std::min(0.0f, l.vel.x * maxT);
        float vx1 = std::max(0.0f, l.vel.x * maxT);
        float vy0 = std::min(0.0f, l.vel.y * maxT);
        float vy1 = std::max(0.0f, l.vel.y * maxT);
        if (l.ring) {
            float ext = l.radius + pad;
            p.minX = l.origin.x + vx0 - ext; p.maxX = l.origin.x + vx1 + ext;
            p.minY = l.origin.y + vy0 - ext; p.maxY = l.origin.y + vy1 + ext;
        } else if (l.angularSpeed != 0.0f || l.numPts <= 0) {
            float ext = l.reach + pad;
            p.minX = l.origin.x + vx0 - ext; p.maxX = l.origin.x + vx1 + ext;
            p.minY = l.origin.y + vy0 - ext; p.maxY = l.origin.y + vy1 + ext;
        } else {
            float lx0 = l.pts[0].x, lx1 = l.pts[0].x;
            float ly0 = l.pts[0].y, ly1 = l.pts[0].y;
            for (int j = 1; j < l.numPts; ++j) {
                lx0 = std::min(lx0, l.pts[j].x); lx1 = std::max(lx1, l.pts[j].x);
                ly0 = std::min(ly0, l.pts[j].y); ly1 = std::max(ly1, l.pts[j].y);
            }
            p.minX = l.origin.x + vx0 + lx0 - pad; p.maxX = l.origin.x + vx1 + lx1 + pad;
            p.minY = l.origin.y + vy0 + ly0 - pad; p.maxY = l.origin.y + vx1 + ly1 + pad;
        }
        bool isTwo = (!l.ring && l.numPts == 2);
        for (int k = 0; k <= maxK; ++k) {
            PrecompLaserStep& st = p.steps[k];
            st.t0 = ((k == 0) ? 0.0f : static_cast<float>(k - 1) * 0.5f) + ep;
            st.t1 = static_cast<float>(k) * 0.5f + ep;
            st.active = !(st.t1 < l.activeFrom || st.t0 > l.timeoutT) && (l.ring || l.numPts >= 2);
            st.twoPts = isTwo;
            if (!st.active || l.ring) continue;
            if (l.angularSpeed == 0.0f || st.t1 <= l.rotDelay) {
                st.midZero = true;
                st.cosA = 1.0f; st.sinA = 0.0f; st.rotMargin = 0.0f;
                if (isTwo) {
                    st.segA = l.pts[0]; st.segB = l.pts[1];
                    st.sMinX = std::min(st.segA.x, st.segB.x); st.sMaxX = std::max(st.segA.x, st.segB.x);
                    st.sMinY = std::min(st.segA.y, st.segB.y); st.sMaxY = std::max(st.segA.y, st.segB.y);
                }
            } else {
                float ang0 = l.angularSpeed * std::max(0.0f, st.t0 - l.rotDelay);
                float ang1 = l.angularSpeed * std::max(0.0f, st.t1 - l.rotDelay);
                float midAng = 0.5f * (ang0 + ang1);
                st.midZero = std::abs(midAng) < 1e-4f;
                if (!st.midZero) {
                    float rad = midAng * 0.0174532925f;
                    st.cosA = std::cos(rad);
                    st.sinA = std::sin(rad);
                } else {
                    st.cosA = 1.0f;
                    st.sinA = 0.0f;
                }
                if (isTwo) {
                    st.segA = {l.pts[0].x * st.cosA - l.pts[0].y * st.sinA,
                               l.pts[0].x * st.sinA + l.pts[0].y * st.cosA};
                    st.segB = {l.pts[1].x * st.cosA - l.pts[1].y * st.sinA,
                               l.pts[1].x * st.sinA + l.pts[1].y * st.cosA};
                    st.sMinX = std::min(st.segA.x, st.segB.x); st.sMaxX = std::max(st.segA.x, st.segB.x);
                    st.sMinY = std::min(st.segA.y, st.segB.y); st.sMaxY = std::max(st.segA.y, st.segB.y);
                }
                st.rotMargin = l.reach * std::abs(ang1 - ang0) * 0.0174532925f * 0.5f;
            }
        }
    }
}

inline float laserClearanceAtStepPre(const LaserHazard& l, const PrecompLaserStep& ps,
                                     Vec2 p0, Vec2 p1, float playerRadius, float gapMargin = 24.0f) {
    if (!ps.active) return -1e6f;
    float radSum = playerRadius + l.width;
    Vec2 a{p0.x - l.origin.x - l.vel.x * ps.t0, p0.y - l.origin.y - l.vel.y * ps.t0};
    Vec2 b{p1.x - l.origin.x - l.vel.x * ps.t1, p1.y - l.origin.y - l.vel.y * ps.t1};

    if (l.ring) {
        float nearD = std::sqrt(pointSegmentDistSq(0.0f, 0.0f, a.x, a.y, b.x, b.y));
        float farD = std::sqrt(std::max(a.lengthSq(), b.lengthSq()));
        float shellGap = std::max({nearD - l.radius, l.radius - farD, 0.0f});
        return radSum - shellGap;
    }

    if (ps.twoPts) {
        float effRad = radSum + ps.rotMargin;
        float pad = effRad + gapMargin;
        if (std::max(a.x, b.x) + pad < ps.sMinX || std::min(a.x, b.x) - pad > ps.sMaxX ||
            std::max(a.y, b.y) + pad < ps.sMinY || std::min(a.y, b.y) - pad > ps.sMaxY) {
            return -24.0f;
        }
        float d2 = segmentSegmentDistSq(a.x, a.y, b.x, b.y, ps.segA.x, ps.segA.y, ps.segB.x, ps.segB.y);
        if (d2 >= pad * pad) return -24.0f;
        return effRad - std::sqrt(d2);
    }

    float minDistSq = 1e12f;
    if (ps.midZero) {
        for (int i = 1; i < l.numPts; ++i) {
            float d2 = segmentSegmentDistSq(a.x, a.y, b.x, b.y,
                                            l.pts[i - 1].x, l.pts[i - 1].y,
                                            l.pts[i].x, l.pts[i].y);
            if (d2 < minDistSq) minDistSq = d2;
        }
    } else {
        float c = ps.cosA, s = ps.sinA;
        Vec2 prev{l.pts[0].x * c - l.pts[0].y * s, l.pts[0].x * s + l.pts[0].y * c};
        for (int i = 1; i < l.numPts; ++i) {
            Vec2 cur{l.pts[i].x * c - l.pts[i].y * s, l.pts[i].x * s + l.pts[i].y * c};
            float d2 = segmentSegmentDistSq(a.x, a.y, b.x, b.y, prev.x, prev.y, cur.x, cur.y);
            if (d2 < minDistSq) minDistSq = d2;
            prev = cur;
        }
    }
    float effRad = radSum + ps.rotMargin;
    float pad = effRad + gapMargin;
    if (minDistSq >= pad * pad) return -24.0f;
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
    float minX = 0.0f, maxX = 0.0f, minY = 0.0f, maxY = 0.0f;
    float tMinX = 0.0f, tMaxX = 0.0f, tMinY = 0.0f, tMaxY = 0.0f;
    Vec2 path[BulletTrack::kMaxPts]{};
    Vec2 vels[BulletTrack::kMaxPts]{};
    Vec2 twinPath[BulletTrack::kMaxPts]{};
    Vec2 twinVels[BulletTrack::kMaxPts]{};
    bool movedAt[BulletTrack::kMaxPts]{};
    RolloutSnapshot snaps[3]{};
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
            float cut = grid.lRoomCutoutOverflow(px, py, 0.0f);
            if (cut > 0.0f) over += cut;
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
    for (int i = 0; i < 9; ++i) {
        float px = x + kOx[i] * r;
        float py = y + kOy[i] * r;
        float over = boundsOverflow(px, py);
        if (over > 0.0f) {
            pen += 200.0f + over * 20.0f;
            continue;
        }
        int idx = grid.indexAt(px, py);
        if (idx < 0) {
            pen += 200.0f;
            continue;
        }
        if (!grid.cellPhysicallyPassable(idx, canFly)) {
            Vec2 ctr = grid.cellCenter(idx);
            float depth = std::min(std::max(0.0f, grid.pitch.x * 0.5f - std::abs(px - ctr.x)),
                                   std::max(0.0f, grid.pitch.y * 0.5f - std::abs(py - ctr.y)));
            pen += 100.0f * (1.0f + depth);
        }
    }
    return pen;
}

// Advance one 60Hz player update (`pos += vel`, NOT `0.5 * vel`!) with physical terrain slide.
inline void stepPlayer60(const RoomGrid& grid, float playerSize, bool canFly,
                         bool originUnsafe, Vec2 dir, const PlayerKinematics& kin,
                         Vec2& pos, Vec2& vel, bool& moved) {
    if (dir.lengthSq() < 1e-6f) {
        vel *= kin.fIdle;
    } else {
        vel = vel * kin.fDrive + dir * kin.accel;
    }
    Vec2 delta = vel;
    float distSq = delta.lengthSq();
    if (distSq < 1e-8f) return;

    auto canMoveTo = [&](Vec2 q, Vec2 from) -> bool {
        if (grid.footprintSafe(q.x, q.y, playerSize, canFly)) return true;
        if (!originUnsafe) return false;
        if (grid.footprintSafe(from.x, from.y, playerSize, canFly)) return false;
        return footprintPenalty(grid, q.x, q.y, playerSize, canFly) <
               footprintPenalty(grid, from.x, from.y, playerSize, canFly) - 0.02f;
    };

    int sub = (distSq <= 36.0f) ? 1 : std::min(4, std::max(1, static_cast<int>(std::ceil(std::sqrt(distSq) / 6.0f))));
    for (int s = 0; s < sub; ++s) {
        Vec2 step = delta * (1.0f / static_cast<float>(sub));
        Vec2 cand = pos + step;
        if (canMoveTo(cand, pos)) {
            pos = cand;
            moved = true;
            continue;
        }
        bool slideX = (std::abs(step.x) > 1e-4f) && canMoveTo({pos.x + step.x, pos.y}, pos);
        bool slideY = (std::abs(step.y) > 1e-4f) && canMoveTo({pos.x, pos.y + step.y}, pos);
        if (slideX && !slideY) {
            pos.x += step.x; vel.y = 0.0f; moved = true;
        } else if (slideY && !slideX) {
            pos.y += step.y; vel.x = 0.0f; moved = true;
        } else {
            vel = {0.0f, 0.0f};
            break;
        }
    }
}

inline bool sampleBodyRange(const ThreatScene& scene,
                            const std::vector<PrecompLaser>& preLasers,
                            const Vec2* path, float pMinX, float pMaxX, float pMinY, float pMaxY,
                            float bodyRadius, bool bodyCanFly, bool allowPickups,
                            int kStart, int kEnd, int maxK,
                            float* stepHardMax, float* stepWarnMax, float* stepMinGap,
                            RolloutState& st, int abortFirstHardLe, int abortLastHardGt,
                            bool abortAnyWarn, bool onlyEndGap) {
    float ep = scene.entityPhase;

    // 1. Bullets outer loop (b.pts[k] is already phase-aligned with player step k)
    for (const BulletTrack& b : scene.bullets) {
        int lo = std::max(kStart, b.firstStep);
        int hi = std::min(kEnd, b.lastStep);
        if (lo > hi) continue;
        float pad = b.radius + bodyRadius + 1.0f;
        if (pMaxX + pad < b.minX || pMinX - pad > b.maxX ||
            pMaxY + pad < b.minY || pMinY - pad > b.maxY) {
            continue;
        }
        float rs = bodyRadius + b.radius;
        for (int k = lo; k <= hi; ++k) {
            Vec2 p0 = (k == 0) ? path[0] : path[k - 1];
            Vec2 q0 = (k == 0) ? b.pts[0] : b.pts[k - 1];
            float gm = (!onlyEndGap || k == maxK) ? 24.0f : 0.0f;
            float pen = sweptRelativeClearance(p0, path[k], q0, b.pts[k], rs, gm);
            if (pen > 0.0f) {
                if (b.warning) {
                    stepWarnMax[k] = std::max(stepWarnMax[k], pen);
                    if (abortAnyWarn) { st.hasWarn = true; return true; }
                } else {
                    stepHardMax[k] = std::max(stepHardMax[k], pen);
                    if ((abortFirstHardLe >= 0 && std::min(st.firstHardK, k) <= abortFirstHardLe) ||
                        (abortLastHardGt >= 0 && k > abortLastHardGt)) {
                        st.hasHard = true;
                        st.firstHardK = std::min(st.firstHardK, k);
                        st.lastHardK = std::max(st.lastHardK, k);
                        return true;
                    }
                }
                stepMinGap[k] = 0.0f;
            } else {
                stepMinGap[k] = std::min(stepMinGap[k], -pen);
            }
        }
    }

    // 2. Discs & capsules outer loop
    for (const DiscHazard& d : scene.discs) {
        if (d.groundOnly && bodyCanFly) continue;
        if (d.autoOnly && allowPickups) continue;

        int lo = kStart;
        if (d.fromT > ep) {
            lo = std::max(lo, static_cast<int>(std::ceil((d.fromT - ep) * 2.0f - 1e-4f)));
        }
        int hi = kEnd;
        if (d.toT < 1e5f) {
            hi = std::min(hi, static_cast<int>(std::floor((d.toT - ep) * 2.0f + 1.0f + 1e-4f)));
        }
        if (lo > hi) continue;

        float tA = ((lo == 0) ? 0.0f : static_cast<float>(lo - 1) * 0.5f) + ep;
        float tB = static_cast<float>(hi) * 0.5f + ep;
        Vec2 cA = d.pos + d.vel * tA;
        Vec2 cB = d.pos + d.vel * tB;
        float dMinX = std::min(cA.x, cB.x), dMaxX = std::max(cA.x, cB.x);
        float dMinY = std::min(cA.y, cB.y), dMaxY = std::max(cA.y, cB.y);
        if (d.isCapsule) {
            Vec2 cA2 = cA + d.sweepEndOffset;
            Vec2 cB2 = cB + d.sweepEndOffset;
            dMinX = std::min({dMinX, cA2.x, cB2.x});
            dMaxX = std::max({dMaxX, cA2.x, cB2.x});
            dMinY = std::min({dMinY, cA2.y, cB2.y});
            dMaxY = std::max({dMaxY, cA2.y, cB2.y});
        }
        float pad = d.radius + bodyRadius + 1.0f;
        if (pMaxX + pad < dMinX || pMinX - pad > dMaxX ||
            pMaxY + pad < dMinY || pMinY - pad > dMaxY) {
            continue;
        }
        float rs = bodyRadius + d.radius;
        for (int k = lo; k <= hi; ++k) {
            float t0 = ((k == 0) ? 0.0f : static_cast<float>(k - 1) * 0.5f) + ep;
            float t1 = static_cast<float>(k) * 0.5f + ep;
            if (t1 < d.fromT || t0 > d.toT) continue;
            Vec2 p0 = (k == 0) ? path[0] : path[k - 1];
            float gm = (!onlyEndGap || k == maxK) ? 24.0f : 0.0f;
            float pen = d.isCapsule
                ? sweptCapsuleClearance(p0, path[k], d.pos + d.vel * t0, d.pos + d.vel * t1 + d.sweepEndOffset, rs, gm)
                : sweptRelativeClearance(p0, path[k], d.pos + d.vel * t0, d.pos + d.vel * t1, rs, gm);
            if (pen > 0.0f) {
                if (d.warning) {
                    stepWarnMax[k] = std::max(stepWarnMax[k], pen);
                    if (abortAnyWarn) { st.hasWarn = true; return true; }
                } else {
                    stepHardMax[k] = std::max(stepHardMax[k], pen);
                    if ((abortFirstHardLe >= 0 && std::min(st.firstHardK, k) <= abortFirstHardLe) ||
                        (abortLastHardGt >= 0 && k > abortLastHardGt)) {
                        st.hasHard = true;
                        st.firstHardK = std::min(st.firstHardK, k);
                        st.lastHardK = std::max(st.lastHardK, k);
                        return true;
                    }
                }
                stepMinGap[k] = 0.0f;
            } else {
                stepMinGap[k] = std::min(stepMinGap[k], -pen);
            }
        }
    }

    // 3. Lasers outer loop using precomputed per-step cos/sin and step segment AABB
    for (size_t li = 0; li < scene.lasers.size(); ++li) {
        const PrecompLaser& pl = preLasers[li];
        float pad = bodyRadius + 1.0f;
        if (pMaxX + pad < pl.minX || pMinX - pad > pl.maxX ||
            pMaxY + pad < pl.minY || pMinY - pad > pl.maxY) {
            continue;
        }
        const LaserHazard& l = scene.lasers[li];
        for (int k = kStart; k <= kEnd; ++k) {
            if (!pl.steps[k].active) continue;
            Vec2 p0 = (k == 0) ? path[0] : path[k - 1];
            float gm = (!onlyEndGap || k == maxK) ? 24.0f : 0.0f;
            float pen = laserClearanceAtStepPre(l, pl.steps[k], p0, path[k], bodyRadius, gm);
            if (pen > 0.0f) {
                if (l.warning) {
                    stepWarnMax[k] = std::max(stepWarnMax[k], pen);
                    if (abortAnyWarn) { st.hasWarn = true; return true; }
                } else {
                    stepHardMax[k] = std::max(stepHardMax[k], pen);
                    if ((abortFirstHardLe >= 0 && std::min(st.firstHardK, k) <= abortFirstHardLe) ||
                        (abortLastHardGt >= 0 && k > abortLastHardGt)) {
                        st.hasHard = true;
                        st.firstHardK = std::min(st.firstHardK, k);
                        st.lastHardK = std::max(st.lastHardK, k);
                        return true;
                    }
                }
                stepMinGap[k] = 0.0f;
            } else if (pen > -1e5f) {
                stepMinGap[k] = std::min(stepMinGap[k], -pen);
            }
        }
    }

    // 4. AUTO-only pickup/pedestal/mimic cells (never braked in manual mode)
    if (!allowPickups) {
        for (int k = std::max(1, kStart); k <= kEnd; ++k) {
            int idx = scene.grid.indexAt(path[k].x, path[k].y);
            if (scene.grid.cellAutoAvoid(idx)) {
                st.crossedAutoAvoid = true;
                st.hasWarn = true;
                if (abortAnyWarn) return true;
            }
        }
    }
    (void)maxK;
    return false;
}

inline void sampleRolloutRange(const ThreatScene& scene,
                               const std::vector<PrecompLaser>& preLasers,
                               int kStart, int kEnd, int maxK, bool allowPickups,
                               RolloutState& st,
                               int abortFirstHardLe = -1, int abortLastHardGt = -1,
                               bool abortAnyWarn = false, bool onlyEndGap = false) {
    if (kStart > kEnd) return;

    float stepHardMax[BulletTrack::kMaxPts]{};
    float stepWarnMax[BulletTrack::kMaxPts]{};
    float stepMinGap[BulletTrack::kMaxPts];
    for (int k = kStart; k <= kEnd; ++k) stepMinGap[k] = 24.0f;

    if (sampleBodyRange(scene, preLasers, st.path, st.minX, st.maxX, st.minY, st.maxY,
                        scene.player.size, scene.player.canFly, allowPickups,
                        kStart, kEnd, maxK, stepHardMax, stepWarnMax, stepMinGap,
                        st, abortFirstHardLe, abortLastHardGt, abortAnyWarn, onlyEndGap)) {
        return;
    }

    if (scene.hasTwin) {
        if (sampleBodyRange(scene, preLasers, st.twinPath, st.tMinX, st.tMaxX, st.tMinY, st.tMaxY,
                            scene.twin.size, scene.twin.canFly, allowPickups,
                            kStart, kEnd, maxK, stepHardMax, stepWarnMax, stepMinGap,
                            st, abortFirstHardLe, abortLastHardGt, abortAnyWarn, onlyEndGap)) {
            return;
        }
    }

    for (int k = kStart; k <= kEnd; ++k) {
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
    int16_t cost[Offsets::Room::kMaxGridCells]{};
    uint8_t blockedCell[Offsets::Room::kMaxGridCells]{};

    void init(const ThreatScene& scene) {
        const RoomGrid& g = scene.grid;
        for (int i = 0; i < g.cellCount; ++i) {
            cost[i] = -1;
            blockedCell[i] = 0;
        }
        // Mark enemy bodies and static floor hazards so BFS never treats choked/spiked corners as open escape space
        for (const DiscHazard& d : scene.discs) {
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
                for (int cx = c0; cx <= c1; ++cx) {
                    int idx = cx + ry * g.width;
                    if (idx >= 0 && idx < g.cellCount) {
                        Vec2 ctr = g.cellCenter(idx);
                        if ((ctr - d.pos).lengthSq() <= rSq) {
                            blockedCell[idx] = 1;
                        }
                    }
                }
            }
        }
    }
};

inline int scoreEndpointSpace(const ThreatScene& scene, Vec2 endpoint, SpaceBfsCache& cache) {
    const RoomGrid& g = scene.grid;
    if (!g.inBoundsPoint(endpoint.x, endpoint.y, 0.0f)) return 999;
    int idx = g.indexAt(endpoint.x, endpoint.y);
    if (idx < 0 || !g.cellPhysicallyPassable(idx, scene.player.canFly)) return 999;

    int baseCost = cache.cost[idx];
    if (baseCost < 0) {
        int queue[48];
        int depth[48];
        uint8_t seen[Offsets::Room::kMaxGridCells]{};
        int head = 0, tail = 0, exits = 0, reach = 0;
        queue[tail] = idx; depth[tail] = 0; ++tail;
        seen[idx] = 1;

        static constexpr int kDx[4] = {-1, 1, 0, 0};
        static constexpr int kDy[4] = {0, 0, -1, 1};
        while (head < tail && tail < 48) {
            int cur = queue[head];
            int dp = depth[head];
            ++head;
            ++reach;
            if (dp < 4) {
                int cx = cur % g.width;
                int cy = cur / g.width;
                for (int d = 0; d < 4; ++d) {
                    int nx = cx + kDx[d], ny = cy + kDy[d];
                    if (nx < 0 || nx >= g.width || ny < 0 || ny >= g.height) continue;
                    int ni = nx + ny * g.width;
                    if (ni < 0 || ni >= g.cellCount) continue;
                    if (!g.cellPhysicallyPassable(ni, scene.player.canFly) || cache.blockedCell[ni]) continue;
                    Vec2 nc = g.cellCenter(ni);
                    if (!g.inBoundsPoint(nc.x, nc.y, 4.0f)) continue;
                    if (dp == 0) ++exits;
                    if (!seen[ni] && tail < 48) {
                        seen[ni] = 1;
                        queue[tail] = ni; depth[tail] = dp + 1; ++tail;
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
    for (const DiscHazard& d : scene.discs) {
        if (!d.isEnemyBody) continue;
        Vec2 dVec = endpoint - d.pos;
        float distSq = dVec.lengthSq();
        if (distSq < 140.0f * 140.0f) {
            float clear = std::sqrt(distSq) - (d.radius + scene.player.size);
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
                // Keep primary integer tier strictly on exit tick (lastHit + 1) so hysteresis holds steady!
                intRisk = 1000000LL + static_cast<int64_t>(std::max(0, lastHit) + 1);
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
                999999LL,
                trapped + static_cast<int64_t>(std::floor(maxPen * 2000.0f + exposure * 50.0f + hits * 100.0f)));
            intRisk = static_cast<int64_t>(survival) * 1000000LL + sub;
        }
    }

    if (hasWarn) {
        float wWeighted = std::max(fast.warnWeighted, slow.warnWeighted);
        float wPeak = std::max(fast.maxWarnPen, slow.maxWarnPen);
        int64_t wTier = std::max<int64_t>(1LL, std::min<int64_t>(9999LL, static_cast<int64_t>(std::ceil(wWeighted + wPeak * 0.5f))));
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

inline RolloutSnapshot makeSnap(const RolloutState& st, int k) {
    RolloutSnapshot sn{};
    sn.pos = st.path[k];
    sn.vel = st.vels[k];
    sn.twinPos = st.twinPath[k];
    sn.twinVel = st.twinVels[k];
    sn.moved = st.movedAt[k];
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

inline RolloutState simulateStraight(const ThreatScene& scene,
                                     const std::vector<PrecompLaser>& preLasers,
                                     int dir, int rawDir,
                                     bool originUnsafe, bool twinOriginUnsafe, bool allowPickups,
                                     const PlayerKinematics& kin, const PlayerKinematics& twinKin,
                                     int maxK, const int pivots[3], bool recordSnaps) {
    RolloutState st{};
    st.pos = scene.player.pos;
    st.vel = scene.player.vel;
    st.path[0] = st.pos;
    st.vels[0] = st.vel;
    st.movedAt[0] = false;
    st.minX = st.maxX = st.pos.x;
    st.minY = st.maxY = st.pos.y;

    if (scene.hasTwin) {
        st.twinPos = scene.twin.pos;
        st.twinVel = scene.twin.vel;
        st.twinPath[0] = st.twinPos;
        st.twinVels[0] = st.twinVel;
        st.tMinX = st.tMaxX = st.twinPos.x;
        st.tMinY = st.tMaxY = st.twinPos.y;
    }

    int qSteps = std::min(maxK, scene.queueDelay30 * 2 + kin.extraDelay60);
    Vec2 qVec = candVec(rawDir);
    Vec2 dVec = candVec(dir);

    for (int k = 1; k <= maxK; ++k) {
        bool steered = (k > qSteps);
        Vec2 useDir = steered ? dVec : qVec;
        bool stepMoved = false;
        stepPlayer60(scene.grid, scene.player.size, scene.player.canFly,
                     originUnsafe, useDir, kin, st.pos, st.vel, stepMoved);
        if (steered && stepMoved) st.moved = true;
        st.path[k] = st.pos;
        st.vels[k] = st.vel;
        st.movedAt[k] = st.moved;

        if (scene.hasTwin) {
            bool twinMoved = false;
            stepPlayer60(scene.grid, scene.twin.size, scene.twin.canFly,
                         twinOriginUnsafe, useDir, twinKin, st.twinPos, st.twinVel, twinMoved);
            st.twinPath[k] = st.twinPos;
            st.twinVels[k] = st.twinVel;
        }
    }

    // If queueDelay consumed the whole horizon, still test 2 post-queue ticks so blockedMask is physical!
    if (qSteps >= maxK && dir > 0) {
        Vec2 probePos = st.pos, probeVel = st.vel;
        bool probeMoved = false;
        for (int p = 0; p < 2; ++p) {
            stepPlayer60(scene.grid, scene.player.size, scene.player.canFly,
                         originUnsafe, dVec, kin, probePos, probeVel, probeMoved);
        }
        st.moved = probeMoved;
    }

    auto expandBounds = [&](int fromK, int toK) {
        for (int k = std::max(1, fromK); k <= toK; ++k) {
            st.minX = std::min(st.minX, st.path[k].x); st.maxX = std::max(st.maxX, st.path[k].x);
            st.minY = std::min(st.minY, st.path[k].y); st.maxY = std::max(st.maxY, st.path[k].y);
            if (scene.hasTwin) {
                st.tMinX = std::min(st.tMinX, st.twinPath[k].x); st.tMaxX = std::max(st.tMaxX, st.twinPath[k].x);
                st.tMinY = std::min(st.tMinY, st.twinPath[k].y); st.tMaxY = std::max(st.tMaxY, st.twinPath[k].y);
            }
        }
    };

    if (!recordSnaps) {
        expandBounds(1, maxK);
        sampleRolloutRange(scene, preLasers, 0, maxK, maxK, allowPickups, st);
        return st;
    }

    // Incremental hazard chunks at dynamic post-queue pivots so prefix states are exact in a single pass
    int curStart = 0;
    for (int ci = 0; ci < 3; ++ci) {
        int cEnd = std::min(maxK, pivots[ci]);
        if (cEnd >= curStart) {
            expandBounds(curStart, cEnd);
            sampleRolloutRange(scene, preLasers, curStart, cEnd, maxK, allowPickups, st);
            curStart = cEnd + 1;
        }
        st.snaps[ci] = makeSnap(st, cEnd);
    }
    if (curStart <= maxK) {
        expandBounds(curStart, maxK);
        sampleRolloutRange(scene, preLasers, curStart, maxK, maxK, allowPickups, st);
    }
    return st;
}

inline RolloutState continueAfterPivotSnap(const ThreatScene& scene,
                                           const std::vector<PrecompLaser>& preLasers,
                                           const RolloutSnapshot& sn, int pivotK,
                                           int dir2, int rawDir,
                                           bool originUnsafe, bool twinOriginUnsafe, bool allowPickups,
                                           const PlayerKinematics& kin, const PlayerKinematics& twinKin,
                                           int maxK, int abortFirstHardLe = -1, int abortLastHardGt = -1,
                                           bool abortAnyWarn = false, int maxEndDepthBucket = -1) {
    RolloutState st{};
    st.pos = sn.pos;
    st.vel = sn.vel;
    st.twinPos = sn.twinPos;
    st.twinVel = sn.twinVel;
    st.moved = sn.moved;
    st.hasHard = sn.hasHard;
    st.hasWarn = sn.hasWarn;
    st.crossedAutoAvoid = sn.crossedAutoAvoid;
    st.firstHardK = sn.firstHardK;
    st.lastHardK = sn.lastHardK;
    st.hardHitSteps = sn.hardHitSteps;
    st.maxHardPen = sn.maxHardPen;
    st.endHardPen = sn.endHardPen;
    st.hardExposure = sn.hardExposure;
    st.maxWarnPen = sn.maxWarnPen;
    st.warnWeighted = sn.warnWeighted;
    st.minClearance = sn.minClearance;
    st.endClearance = sn.endClearance;

    int clampedPivot = std::min(maxK, pivotK);
    st.minX = st.maxX = st.pos.x;
    st.minY = st.maxY = st.pos.y;
    st.path[clampedPivot] = st.pos;
    if (scene.hasTwin) {
        st.tMinX = st.tMaxX = st.twinPos.x;
        st.tMinY = st.tMaxY = st.twinPos.y;
        st.twinPath[clampedPivot] = st.twinPos;
    }
    if (clampedPivot >= maxK) return st;

    int qSteps = std::min(maxK, scene.queueDelay30 * 2 + kin.extraDelay60);
    Vec2 qVec = candVec(rawDir);
    Vec2 dVec = candVec(dir2);
    for (int k = clampedPivot + 1; k <= maxK; ++k) {
        bool steered = (k > qSteps);
        Vec2 useDir = steered ? dVec : qVec;
        bool stepMoved = false;
        stepPlayer60(scene.grid, scene.player.size, scene.player.canFly,
                     originUnsafe, useDir, kin, st.pos, st.vel, stepMoved);
        if (steered && stepMoved) st.moved = true;
        st.path[k] = st.pos;
        st.minX = std::min(st.minX, st.pos.x); st.maxX = std::max(st.maxX, st.pos.x);
        st.minY = std::min(st.minY, st.pos.y); st.maxY = std::max(st.maxY, st.pos.y);

        if (scene.hasTwin) {
            bool twinMoved = false;
            stepPlayer60(scene.grid, scene.twin.size, scene.twin.canFly,
                         twinOriginUnsafe, useDir, twinKin, st.twinPos, st.twinVel, twinMoved);
            st.twinPath[k] = st.twinPos;
            st.tMinX = std::min(st.tMinX, st.twinPos.x); st.tMaxX = std::max(st.tMaxX, st.twinPos.x);
            st.tMinY = std::min(st.tMinY, st.twinPos.y); st.tMaxY = std::max(st.tMaxY, st.twinPos.y);
        }
    }
    if (maxEndDepthBucket >= 0) {
        // Test terminal step k == maxK first (1 step vs 25): if k == maxK has a deeper hit than target,
        // lastHardK == maxK is guaranteed and depthBucket > maxEndDepthBucket cannot improve targetScore!
        float savedMinX = st.minX, savedMaxX = st.maxX, savedMinY = st.minY, savedMaxY = st.maxY;
        Vec2 pPrev = st.path[maxK - 1], pEnd = st.path[maxK];
        st.minX = std::min(pPrev.x, pEnd.x); st.maxX = std::max(pPrev.x, pEnd.x);
        st.minY = std::min(pPrev.y, pEnd.y); st.maxY = std::max(pPrev.y, pEnd.y);
        sampleRolloutRange(scene, preLasers, maxK, maxK, maxK, allowPickups, st, -1, -1, false, true);
        st.minX = savedMinX; st.maxX = savedMaxX; st.minY = savedMinY; st.maxY = savedMaxY;
        if (st.endHardPen > 0.0f &&
            std::min(999, static_cast<int>(std::floor(st.endHardPen * 4.0f))) > maxEndDepthBucket) {
            return st;
        }
        if (clampedPivot + 1 <= maxK - 1) {
            sampleRolloutRange(scene, preLasers, clampedPivot + 1, maxK - 1, maxK, allowPickups, st,
                               abortFirstHardLe, abortLastHardGt, abortAnyWarn, true);
        }
        return st;
    }
    sampleRolloutRange(scene, preLasers, clampedPivot + 1, maxK, maxK, allowPickups, st,
                       abortFirstHardLe, abortLastHardGt, abortAnyWarn, true);
    return st;
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

    auto kinFast = planner_detail::PlayerKinematics::fast(pl);
    auto kinSlow = planner_detail::PlayerKinematics::slow(pl);
    auto twinFast = scene.hasTwin ? planner_detail::PlayerKinematics::fast(scene.twin) : kinFast;
    auto twinSlow = scene.hasTwin ? planner_detail::PlayerKinematics::slow(scene.twin) : kinSlow;

    bool originUnsafe = !grid.footprintSafe(pl.pos.x, pl.pos.y, pl.size, pl.canFly);
    bool twinOriginUnsafe = scene.hasTwin &&
                            !grid.footprintSafe(scene.twin.pos.x, scene.twin.pos.y, scene.twin.size, scene.twin.canFly);

    // Fast path: empty threat scene checks physical terrain blocking only (unless AUTO needs pedestal avoidance)
    if (scene.bullets.empty() && scene.discs.empty() && scene.lasers.empty() &&
        (allowPickups || !planner_detail::hasAnyAutoAvoidCell(grid))) {
        int qSteps = scene.queueDelay30 * 2;
        int probeK = std::min(BulletTrack::kMaxPts - 1, std::max(maxK, qSteps + 6));
        Vec2 qVec = candVec(rawWorldDir);
        for (int d = 1; d < 9; ++d) {
            Vec2 pos = pl.pos, vel = pl.vel;
            bool moved = false;
            Vec2 dVec = candVec(d);
            for (int k = 1; k <= probeK; ++k) {
                bool steered = (k > qSteps);
                bool stepMoved = false;
                planner_detail::stepPlayer60(grid, pl.size, pl.canFly, originUnsafe,
                                             steered ? dVec : qVec, kinFast, pos, vel, stepMoved);
                if (steered && stepMoved) moved = true;
            }
            if (!moved) res.blockedMask |= (1 << d);
        }
        res.danger = false;
        res.bestDir = -1;
        return res;
    }

    std::vector<planner_detail::PrecompLaser> preLasers;
    planner_detail::prepareLasers(scene, maxK, preLasers);
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
        sFast[d] = planner_detail::simulateStraight(
            scene, preLasers, d, rawWorldDir, originUnsafe, twinOriginUnsafe,
            allowPickups, kinFast, twinFast, maxK, pivotsFast, canRecordSnaps);
        sSlow[d] = planner_detail::simulateStraight(
            scene, preLasers, d, rawWorldDir, originUnsafe, twinOriginUnsafe,
            allowPickups, kinSlow, twinSlow, maxK, pivotsSlow, canRecordSnaps);
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

    // 2. Run 2-stage turning trajectory search if all straight routes are risky or graze closely.
    static constexpr double kScale = PlanResult::kScale;
    static constexpr double kHard  = PlanResult::kHard;
    bool needTurnSearch = (bestStraightScore > 0.0) || (bestSafeClearance < 4.0f);

    if (needTurnSearch && canRecordSnaps) {
        double bestOverall = bestStraightScore;
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
                    bool abortWarn = (targetScore < 0.0);
                    auto refreshBounds = [&]() {
                        cutoffK = -1;
                        abortLastGt = -1;
                        maxEndBucket = -1;
                        abortWarn = (targetScore < 0.0);
                        if (abortWarn) {
                            cutoffK = maxK;
                        } else if (!inside) {
                            if (targetScore < kHard) {
                                cutoffK = maxK;
                            } else {
                                int minSurv = static_cast<int>(std::floor(targetScore / kHard));
                                cutoffK = std::max(-1, (maxK + 1) - minSurv);
                            }
                        } else if (targetScore < 2000000.0 * kScale) {
                            int bestTier = static_cast<int>(std::floor(targetScore / kScale));
                            abortLastGt = std::max(0, bestTier - 1000001);
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
                    if (inside && abortLastGt >= 0 &&
                        std::max(snFast.lastHardK, snSlow.lastHardK) > abortLastGt) {
                        continue;
                    }

                    for (int d2 = 0; d2 < 9; ++d2) {
                        if (d2 == d1) continue;
                        auto fullFast = planner_detail::continueAfterPivotSnap(
                            scene, preLasers, snFast, pKFast, d2, rawWorldDir,
                            originUnsafe, twinOriginUnsafe, allowPickups,
                            kinFast, twinFast, maxK, cutoffK, abortLastGt, abortWarn, maxEndBucket);
                        if (abortWarn && (fullFast.hasHard || fullFast.hasWarn || fullFast.crossedAutoAvoid)) continue;
                        if (!inside && fullFast.hasHard && cutoffK >= 0 && fullFast.firstHardK <= cutoffK) continue;
                        if (inside && abortLastGt >= 0 && fullFast.hasHard && fullFast.lastHardK > abortLastGt) continue;
                        if (inside && maxEndBucket >= 0 && fullFast.endHardPen > 0.0f &&
                            std::min(999, static_cast<int>(std::floor(fullFast.endHardPen * 4.0f))) > maxEndBucket) {
                            continue;
                        }

                        auto fullSlow = planner_detail::continueAfterPivotSnap(
                            scene, preLasers, snSlow, pKSlow, d2, rawWorldDir,
                            originUnsafe, twinOriginUnsafe, allowPickups,
                            kinSlow, twinSlow, maxK, cutoffK, abortLastGt, abortWarn, maxEndBucket);
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
        // Only try delayed start (d1=0 -> move d2) when no immediate moving straight/turning route escapes cleanly.
        if (bestMovingScore > 0.0 && bestStraightScore > 0.0) {
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
