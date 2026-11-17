#pragma once

#include "native_predict.hpp"
#include <array>
#include <cmath>

namespace iad {

// 9-direction protocol order: 0 idle, 1 L, 2 R, 3 U, 4 D, 5 LU, 6 RU, 7 LD, 8 RD
inline constexpr float kDiag = 0.7071067811865475f;
inline constexpr float kCandX[9] = {0.0f, -1.0f, 1.0f,  0.0f, 0.0f, -kDiag,  kDiag, -kDiag, kDiag};
inline constexpr float kCandY[9] = {0.0f,  0.0f, 0.0f, -1.0f, 1.0f, -kDiag, -kDiag,  kDiag, kDiag};

inline Vec2 candVec(int dir) {
    return (dir >= 0 && dir < 9) ? Vec2{kCandX[dir], kCandY[dir]} : Vec2{0.0f, 0.0f};
}

struct PlanResult {
    bool valid = false;
    bool danger = false;
    bool inside = false;
    bool usedTurn = false;
    int blockedMask = 0;
    int bestDir = -1;
    double scores[9]{};
};

namespace planner_detail {

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
inline float sweptRelativeClearance(Vec2 p0, Vec2 p1, Vec2 q0, Vec2 q1, float radiusSum) {
    float bound = radiusSum + 24.0f;
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
    float maxT = static_cast<float>(maxK) * 0.5f;
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
            p.minY = l.origin.y + vy0 + ly0 - pad; p.maxY = l.origin.y + vy1 + ly1 + pad;
        }
        bool isTwo = (!l.ring && l.numPts == 2);
        for (int k = 0; k <= maxK; ++k) {
            PrecompLaserStep& st = p.steps[k];
            st.t0 = (k == 0) ? 0.0f : static_cast<float>(k - 1) * 0.5f;
            st.t1 = static_cast<float>(k) * 0.5f;
            st.active = !(st.t1 < l.activeFrom || st.t0 > l.timeoutT) && (l.ring || l.numPts >= 2);
            st.twoPts = isTwo;
            if (!st.active || l.ring) continue;
            if (k == 0 || l.angularSpeed == 0.0f) {
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
                                     Vec2 p0, Vec2 p1, float playerRadius) {
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
        float pad = effRad + 24.0f;
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
    float pad = effRad + 24.0f;
    if (minDistSq >= pad * pad) return -24.0f;
    return effRad - std::sqrt(minDistSq);
}

struct RolloutSnapshot {
    Vec2 pos;
    Vec2 vel;
    bool moved = false;
    bool hasHard = false;
    bool hasWarn = false;
    int firstHardK = 10000;
    int lastHardK = -1;
    float maxHardPen = 0.0f;
    float maxWarnPen = 0.0f;
    float minClearance = 1e6f;
    float minX = 0.0f, maxX = 0.0f, minY = 0.0f, maxY = 0.0f;
};

struct RolloutState {
    Vec2 pos;
    Vec2 vel;
    bool moved = false;
    bool hasHard = false;
    bool hasWarn = false;
    int firstHardK = 10000;
    int lastHardK = -1;
    float maxHardPen = 0.0f;
    float maxWarnPen = 0.0f;
    float minClearance = 1e6f;
    float minX = 0.0f, maxX = 0.0f, minY = 0.0f, maxY = 0.0f;
    Vec2 path[BulletTrack::kMaxPts]{};
    Vec2 vels[BulletTrack::kMaxPts]{};
    bool movedAt[BulletTrack::kMaxPts]{};
    RolloutSnapshot snaps[3]{}; // checkpoints at k = 2, 4, 6
};

inline float footprintPenalty(const RoomGrid& grid, float x, float y, float radius,
                              bool canFly, bool allowPickups) {
    auto boundsOverflow = [&](float px, float py) -> float {
        float over = 0.0f;
        if (!grid.beast) {
            if (px < grid.topLeft.x) over += (grid.topLeft.x - px);
            if (px > grid.bottomRight.x) over += (px - grid.bottomRight.x);
            if (py < grid.topLeft.y) over += (grid.topLeft.y - py);
            if (py > grid.bottomRight.y) over += (py - grid.bottomRight.y);
            if (grid.isLShape()) {
                float midX = (grid.topLeft.x + grid.bottomRight.x) * 0.5f;
                float midY = (grid.topLeft.y + grid.bottomRight.y) * 0.5f;
                bool cutLeft = (grid.shape == 9 || grid.shape == 11);
                bool cutTop = (grid.shape == 9 || grid.shape == 10);
                float dxCut = cutLeft ? (midX - px) : (px - midX);
                float dyCut = cutTop ? (midY - py) : (py - midY);
                if (dxCut > 0.0f && dyCut > 0.0f) {
                    over += std::min(dxCut, dyCut);
                }
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
        bool passSolid = grid.cellPassable(idx, canFly, true, allowPickups);
        bool passClean = grid.cellPassable(idx, canFly, false, allowPickups);
        if (!passSolid || !passClean) {
            int col = idx % grid.width;
            int row = idx / grid.width;
            float cx = grid.origin.x + static_cast<float>(col) * grid.pitch.x;
            float cy = grid.origin.y + static_cast<float>(row) * grid.pitch.y;
            float depth = std::min(std::max(0.0f, grid.pitch.x * 0.5f - std::abs(px - cx)),
                                   std::max(0.0f, grid.pitch.y * 0.5f - std::abs(py - cy)));
            pen += (passSolid ? 10.0f : 100.0f) * (1.0f + depth);
        }
    }
    return pen;
}

// Advance one 60Hz sub-step (`dt = 0.5f` of a 30Hz update) with swept terrain slide.
inline void stepPlayer60(const RoomGrid& grid, float playerSize, bool canFly,
                         bool originUnsafe, bool allowPickups,
                         Vec2 dir, float f60, float accel60,
                         Vec2& pos, Vec2& vel, bool& moved) {
    vel = vel * f60 + dir * accel60;
    Vec2 delta = vel * 0.5f;
    float distSq = delta.lengthSq();
    if (distSq < 1e-8f) return;

    auto canMoveTo = [&](Vec2 q, Vec2 from) -> bool {
        if (grid.footprintSafe(q.x, q.y, playerSize, canFly, false, allowPickups)) return true;
        if (!originUnsafe) return false;
        // Origin-unsafe recovery: allow steps that strictly stay clear of new walls/hazards
        // or make monotonic sub-pixel progress out of an edge/spike overlap.
        if (grid.footprintSafe(from.x, from.y, playerSize, canFly, false, allowPickups)) return false;
        return footprintPenalty(grid, q.x, q.y, playerSize, canFly, allowPickups) <
               footprintPenalty(grid, from.x, from.y, playerSize, canFly, allowPickups) - 0.02f;
    };

    int sub = (distSq <= 16.0f) ? 1 : std::min(4, std::max(1, static_cast<int>(std::ceil(std::sqrt(distSq) * 0.25f))));
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

inline void sampleRolloutRange(const ThreatScene& scene,
                               const std::vector<PrecompLaser>& preLasers,
                               int kStart, int kEnd, float playerRadius, RolloutState& st,
                               int abortFirstHardLe = -1, bool abortAnyWarn = false) {
    if (kStart > kEnd) return;

    auto recordPen = [&](int k, float pen, uint8_t warn) -> bool {
        if (pen > 0.0f) {
            if (warn) {
                st.hasWarn = true;
                st.maxWarnPen = std::max(st.maxWarnPen, pen);
                if (abortAnyWarn) return true;
            } else {
                st.hasHard = true;
                st.firstHardK = std::min(st.firstHardK, k);
                st.lastHardK = std::max(st.lastHardK, k);
                st.maxHardPen = std::max(st.maxHardPen, pen);
                if (abortFirstHardLe >= 0 && st.firstHardK <= abortFirstHardLe) return true;
            }
            st.minClearance = std::min(st.minClearance, 0.0f);
        } else {
            st.minClearance = std::min(st.minClearance, -pen);
        }
        return false;
    };

    // 1. Bullets outer loop (one AABB check rejects most bullets across [kStart..kEnd])
    for (const BulletTrack& b : scene.bullets) {
        int lo = std::max(kStart, b.firstStep);
        int hi = std::min(kEnd, b.lastStep);
        if (lo > hi) continue;
        float pad = b.radius + playerRadius + 1.0f;
        if (st.maxX + pad < b.minX || st.minX - pad > b.maxX ||
            st.maxY + pad < b.minY || st.minY - pad > b.maxY) {
            continue;
        }
        float rs = playerRadius + b.radius;
        for (int k = lo; k <= hi; ++k) {
            Vec2 p0 = (k == 0) ? st.path[0] : st.path[k - 1];
            Vec2 q0 = (k == 0) ? b.pts[0] : b.pts[k - 1];
            float pen = sweptRelativeClearance(p0, st.path[k], q0, b.pts[k], rs);
            if (recordPen(k, pen, b.warning)) return;
        }
    }

    // 2. Discs outer loop
    for (const DiscHazard& d : scene.discs) {
        int lo = kStart;
        if (d.fromT > 0.0f) lo = std::max(lo, static_cast<int>(std::ceil(d.fromT * 2.0f)));
        int hi = kEnd;
        if (d.toT < 1e5f) hi = std::min(hi, static_cast<int>(std::floor(d.toT * 2.0f + 1.0f)));
        if (lo > hi) continue;
        float tA = (lo == 0) ? 0.0f : static_cast<float>(lo - 1) * 0.5f;
        float tB = static_cast<float>(hi) * 0.5f;
        Vec2 cA = d.pos + d.vel * tA;
        Vec2 cB = d.pos + d.vel * tB;
        float pad = d.radius + playerRadius + 1.0f;
        if (st.maxX + pad < std::min(cA.x, cB.x) || st.minX - pad > std::max(cA.x, cB.x) ||
            st.maxY + pad < std::min(cA.y, cB.y) || st.minY - pad > std::max(cA.y, cB.y)) {
            continue;
        }
        float rs = playerRadius + d.radius;
        for (int k = lo; k <= hi; ++k) {
            float t0 = (k == 0) ? 0.0f : static_cast<float>(k - 1) * 0.5f;
            float t1 = static_cast<float>(k) * 0.5f;
            if (t1 < d.fromT || t0 > d.toT) continue;
            Vec2 p0 = (k == 0) ? st.path[0] : st.path[k - 1];
            float pen = sweptRelativeClearance(p0, st.path[k], d.pos + d.vel * t0, d.pos + d.vel * t1, rs);
            if (recordPen(k, pen, d.warning)) return;
        }
    }

    // 3. Lasers outer loop using precomputed per-step cos/sin and step segment AABB
    for (size_t li = 0; li < scene.lasers.size(); ++li) {
        const PrecompLaser& pl = preLasers[li];
        float pad = playerRadius + 1.0f;
        if (st.maxX + pad < pl.minX || st.minX - pad > pl.maxX ||
            st.maxY + pad < pl.minY || st.minY - pad > pl.maxY) {
            continue;
        }
        const LaserHazard& l = scene.lasers[li];
        for (int k = kStart; k <= kEnd; ++k) {
            if (!pl.steps[k].active) continue;
            Vec2 p0 = (k == 0) ? st.path[0] : st.path[k - 1];
            float pen = laserClearanceAtStepPre(l, pl.steps[k], p0, st.path[k], playerRadius);
            if (pen > -1e5f && recordPen(k, pen, l.warning)) return;
        }
    }
}

struct SpaceBfsCache {
    int16_t cost[Offsets::Room::kMaxGridCells]{};
    SpaceBfsCache() { cost[0] = -2; } // sentinel: reset() must be called
    void reset(int count) {
        for (int i = 0; i < count; ++i) cost[i] = -1;
    }
};

inline int scoreEndpointSpace(const ThreatScene& scene, Vec2 endpoint, SpaceBfsCache& cache) {
    const RoomGrid& g = scene.grid;
    int idx = g.indexAt(endpoint.x, endpoint.y);
    if (idx < 0 || !g.cellPassable(idx, scene.player.canFly, false, true)) return 999;

    int baseCost = cache.cost[idx];
    if (baseCost < 0) {
        // 4-connected bounded BFS (max depth 4, up to 41 reachable cells)
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
                    if (!g.cellPassable(ni, scene.player.canFly, false, true)) continue;
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
    float marginX = std::min(endpoint.x - g.topLeft.x, g.bottomRight.x - endpoint.x);
    float marginY = std::min(endpoint.y - g.topLeft.y, g.bottomRight.y - endpoint.y);
    float wallClear = std::min(marginX, marginY);
    if (wallClear < 24.0f) cost += static_cast<int>((24.0f - wallClear) * 4.0f);
    return std::min(999, std::max(0, cost));
}

inline double computeRolloutScore(const ThreatScene& scene, const RolloutState& fast,
                                  const RolloutState& slow, bool inside,
                                  int dir1, int prevChosen, int rawDir, bool isTurn,
                                  SpaceBfsCache& cache) {
    static constexpr double kScale = 1048576.0;
    static constexpr double kHard = kScale * 1000000.0;

    bool hasHard = fast.hasHard || slow.hasHard;
    bool hasWarn = fast.hasWarn || slow.hasWarn;
    double risk = 0.0;

    if (hasHard) {
        int firstHit = std::min(fast.firstHardK, slow.firstHardK);
        int lastHit = std::max(fast.lastHardK, slow.lastHardK);
        float maxPen = std::max(fast.maxHardPen, slow.maxHardPen);
        if (inside) {
            // Exiting sooner dominates everything when currently inside a hazard
            risk = kHard * static_cast<double>(lastHit + 1) +
                   static_cast<double>(std::max(0.0f, maxPen)) * kScale;
        } else {
            // Surviving more ticks before unavoidable hit dominates shallower hits
            int survival = std::max(0, scene.steps60 + 2 - firstHit);
            risk = kHard * static_cast<double>(survival) +
                   static_cast<double>(std::max(0.0f, maxPen)) * kScale;
        }
    } else if (hasWarn) {
        float wPen = std::max(fast.maxWarnPen, slow.maxWarnPen);
        risk = kScale * (1.0 + static_cast<double>(std::min(200.0f, wPen)));
    }

    int space = std::max(scoreEndpointSpace(scene, fast.pos, cache), scoreEndpointSpace(scene, slow.pos, cache));
    float minGap = std::min(fast.minClearance, slow.minClearance);
    int cost = std::min(999, static_cast<int>(space * 0.6f + std::max(0.0f, 24.0f - minGap) * 8.0f));
    int pref = 0;
    if (dir1 == 0) pref = 0;
    else if (dir1 == prevChosen) pref = 4;
    else if (dir1 == rawDir) pref = 8;
    else pref = 20;
    if (isTurn) pref += 64; // slight preference for straight when already equal safety

    double tie = static_cast<double>(std::min(1023, cost)) * 1024.0 +
                 static_cast<double>(std::min(1023, pref));

    if (risk == 0.0) {
        // Negative score when danger exists makes safe > risky trivial while ordering safe routes cleanly
        return tie - kScale;
    }
    return risk + tie;
}

inline RolloutSnapshot makeSnap(const RolloutState& st, int k) {
    RolloutSnapshot sn{};
    sn.pos = st.path[k];
    sn.vel = st.vels[k];
    sn.moved = st.movedAt[k];
    sn.hasHard = st.hasHard;
    sn.hasWarn = st.hasWarn;
    sn.firstHardK = st.firstHardK;
    sn.lastHardK = st.lastHardK;
    sn.maxHardPen = st.maxHardPen;
    sn.maxWarnPen = st.maxWarnPen;
    sn.minClearance = st.minClearance;
    sn.minX = st.minX; sn.maxX = st.maxX; sn.minY = st.minY; sn.maxY = st.maxY;
    return sn;
}

inline RolloutState simulateStraight(const ThreatScene& scene,
                                     const std::vector<PrecompLaser>& preLasers,
                                     int dir, int rawDir,
                                     bool originUnsafe, bool allowPickups,
                                     float f60, float accel60, int maxK, bool recordSnaps) {
    RolloutState st{};
    st.pos = scene.player.pos;
    st.vel = scene.player.vel;
    st.path[0] = st.pos;
    st.vels[0] = st.vel;
    st.movedAt[0] = false;
    st.minX = st.maxX = st.pos.x;
    st.minY = st.maxY = st.pos.y;
    int qSteps = std::min(maxK, scene.queueDelay30 * 2);
    Vec2 qVec = candVec(rawDir);
    Vec2 dVec = candVec(dir);

    for (int k = 1; k <= maxK; ++k) {
        Vec2 useDir = (k <= qSteps) ? qVec : dVec;
        stepPlayer60(scene.grid, scene.player.size, scene.player.canFly,
                     originUnsafe, allowPickups, useDir, f60, accel60,
                     st.pos, st.vel, st.moved);
        st.path[k] = st.pos;
        st.vels[k] = st.vel;
        st.movedAt[k] = st.moved;
    }

    if (!recordSnaps || maxK < 6) {
        for (int k = 1; k <= maxK; ++k) {
            st.minX = std::min(st.minX, st.path[k].x); st.maxX = std::max(st.maxX, st.path[k].x);
            st.minY = std::min(st.minY, st.path[k].y); st.maxY = std::max(st.maxY, st.path[k].y);
        }
        sampleRolloutRange(scene, preLasers, 0, maxK, scene.player.size, st);
        return st;
    }

    // Incremental hazard chunks so snapshots at k = 2, 4, 6 capture exact prefix states in one pass!
    static constexpr int kChunks[3] = {2, 4, 6};
    int curStart = 0;
    for (int ci = 0; ci < 3; ++ci) {
        int cEnd = kChunks[ci];
        for (int k = std::max(1, curStart); k <= cEnd; ++k) {
            st.minX = std::min(st.minX, st.path[k].x); st.maxX = std::max(st.maxX, st.path[k].x);
            st.minY = std::min(st.minY, st.path[k].y); st.maxY = std::max(st.maxY, st.path[k].y);
        }
        sampleRolloutRange(scene, preLasers, curStart, cEnd, scene.player.size, st);
        st.snaps[ci] = makeSnap(st, cEnd);
        curStart = cEnd + 1;
    }
    if (curStart <= maxK) {
        for (int k = curStart; k <= maxK; ++k) {
            st.minX = std::min(st.minX, st.path[k].x); st.maxX = std::max(st.maxX, st.path[k].x);
            st.minY = std::min(st.minY, st.path[k].y); st.maxY = std::max(st.maxY, st.path[k].y);
        }
        sampleRolloutRange(scene, preLasers, curStart, maxK, scene.player.size, st);
    }
    return st;
}

inline RolloutState continueAfterPivotSnap(const ThreatScene& scene,
                                           const std::vector<PrecompLaser>& preLasers,
                                           const RolloutSnapshot& sn, int pivotK,
                                           int dir2, int rawDir,
                                           bool originUnsafe, bool allowPickups,
                                           float f60, float accel60, int maxK,
                                           int abortFirstHardLe = -1, bool abortAnyWarn = false) {
    RolloutState st{};
    st.pos = sn.pos;
    st.vel = sn.vel;
    st.moved = sn.moved;
    st.hasHard = sn.hasHard;
    st.hasWarn = sn.hasWarn;
    st.firstHardK = sn.firstHardK;
    st.lastHardK = sn.lastHardK;
    st.maxHardPen = sn.maxHardPen;
    st.maxWarnPen = sn.maxWarnPen;
    st.minClearance = sn.minClearance;
    st.minX = st.maxX = st.pos.x;
    st.minY = st.maxY = st.pos.y;
    st.path[pivotK] = st.pos;

    int qSteps = std::min(maxK, scene.queueDelay30 * 2);
    Vec2 qVec = candVec(rawDir);
    Vec2 dVec = candVec(dir2);
    for (int k = pivotK + 1; k <= maxK; ++k) {
        Vec2 useDir = (k <= qSteps) ? qVec : dVec;
        stepPlayer60(scene.grid, scene.player.size, scene.player.canFly,
                     originUnsafe, allowPickups, useDir, f60, accel60,
                     st.pos, st.vel, st.moved);
        st.path[k] = st.pos;
        st.minX = std::min(st.minX, st.pos.x); st.maxX = std::max(st.maxX, st.pos.x);
        st.minY = std::min(st.minY, st.pos.y); st.maxY = std::max(st.maxY, st.pos.y);
    }
    sampleRolloutRange(scene, preLasers, pivotK + 1, maxK, scene.player.size, st,
                       abortFirstHardLe, abortAnyWarn);
    return st;
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

    float f30Fast = pl.slippery ? 0.96f : 0.775f;
    float f30Slow = pl.slippery ? 0.975f : 0.84f;
    float f60Fast = std::sqrt(f30Fast);
    float f60Slow = std::sqrt(f30Slow);
    float accel60Fast = 6.0f * pl.moveSpeed * (1.0f - f60Fast);
    float accel60Slow = 6.0f * pl.moveSpeed * (1.0f - f60Slow);

    bool originSafe = grid.footprintSafe(pl.pos.x, pl.pos.y, pl.size, pl.canFly, false, allowPickups);
    bool originUnsafe = !originSafe;

    std::vector<planner_detail::PrecompLaser> preLasers;

    // Fast path: empty threat scene checks terrain blocking only (and respects manual input)
    if (scene.bullets.empty() && scene.discs.empty() && scene.lasers.empty()) {
        int probeK = std::min(6, maxK);
        for (int d = 1; d < 9; ++d) {
            Vec2 pos = pl.pos, vel = pl.vel;
            bool moved = false;
            Vec2 dVec = candVec(d);
            Vec2 qVec = candVec(rawWorldDir);
            int qSteps = std::min(probeK, scene.queueDelay30 * 2);
            for (int k = 1; k <= probeK; ++k) {
                planner_detail::stepPlayer60(grid, pl.size, pl.canFly, originUnsafe, allowPickups,
                                             (k <= qSteps) ? qVec : dVec, f60Fast, accel60Fast,
                                             pos, vel, moved);
            }
            if (!moved) res.blockedMask |= (1 << d);
        }
        res.danger = false;
        res.bestDir = -1;
        return res;
    }

    planner_detail::prepareLasers(scene, maxK, preLasers);
    planner_detail::SpaceBfsCache bfsCache;
    bfsCache.reset(grid.cellCount);

    // 1. Evaluate all 9 straight candidates (collecting prefix snapshots at k = 2, 4, 6)
    std::array<planner_detail::RolloutState, 9> sFast{}, sSlow{};
    double straightScores[9]{};
    bool inside = false;
    bool anyDanger = false;

    for (int d = 0; d < 9; ++d) {
        sFast[d] = planner_detail::simulateStraight(scene, preLasers, d, rawWorldDir, originUnsafe,
                                                    allowPickups, f60Fast, accel60Fast, maxK, true);
        sSlow[d] = planner_detail::simulateStraight(scene, preLasers, d, rawWorldDir, originUnsafe,
                                                    allowPickups, f60Slow, accel60Slow, maxK, true);
        if (d > 0 && !sFast[d].moved && !sSlow[d].moved) {
            res.blockedMask |= (1 << d);
        }
        if (sFast[d].hasHard || sSlow[d].hasHard || sFast[d].hasWarn || sSlow[d].hasWarn) {
            anyDanger = true;
        }
        if (sFast[d].firstHardK == 0 || sSlow[d].firstHardK == 0) {
            inside = true;
        }
    }

    res.inside = inside;
    res.danger = anyDanger;

    if (!anyDanger) {
        for (int d = 0; d < 9; ++d) res.scores[d] = 0.0;
        res.bestDir = -1;
        return res;
    }

    double bestStraightScore = 1e30;
    float bestSafeClearance = 0.0f;
    for (int d = 0; d < 9; ++d) {
        double s = planner_detail::computeRolloutScore(
            scene, sFast[d], sSlow[d], inside, d, prevChosenWorld, rawWorldDir, false, bfsCache);
        straightScores[d] = s;
        res.scores[d] = s;
        if ((d == 0 || (res.blockedMask & (1 << d)) == 0) && s < bestStraightScore) {
            bestStraightScore = s;
            bestSafeClearance = std::min(sFast[d].minClearance, sSlow[d].minClearance);
        }
    }

    // Check if manual input (rawWorldDir, 0 = idle) is already completely straight-safe
    int checkManual = (rawWorldDir >= 0 && rawWorldDir < 9) ? rawWorldDir : 0;
    if ((checkManual == 0 || (res.blockedMask & (1 << checkManual)) == 0) && straightScores[checkManual] <= 0.0) {
        res.bestDir = -1; // manual input is safe: passthrough!
        return res;
    }

    // 2. Run 2-stage turning trajectory search if all straight routes are risky/tight.
    static constexpr double kScale = 1048576.0;
    static constexpr double kHard = kScale * 1000000.0;
    bool needTurnSearch = (bestStraightScore > 0.0) || (bestSafeClearance < 4.0f);

    if (needTurnSearch && maxK >= 6) {
        static constexpr int kPivots[3] = {2, 4, 6};
        double bestOverall = bestStraightScore;
        auto searchTurnRange = [&](int dBegin, int dEnd) {
            for (int pIdx = 0; pIdx < 3; ++pIdx) {
                int pK = kPivots[pIdx];
                if (pK >= maxK - 1) continue;
                for (int d1 = dBegin; d1 <= dEnd; ++d1) {
                    if (d1 > 0 && (res.blockedMask & (1 << d1)) != 0) continue;
                    const auto& snFast = sFast[d1].snaps[pIdx];
                    const auto& snSlow = sSlow[d1].snaps[pIdx];
                    if (d1 > 0 && !snFast.moved && !snSlow.moved) continue;
                    // Prune strictly dominated prefixes before checking any d2
                    if (bestOverall < 0.0 && (snFast.hasHard || snSlow.hasHard || snFast.hasWarn || snSlow.hasWarn)) {
                        continue;
                    }
                    if (!inside && (snFast.hasHard || snSlow.hasHard)) {
                        int pf = std::min(snFast.firstHardK, snSlow.firstHardK);
                        double lowerBound = kHard * static_cast<double>(std::max(0, scene.steps60 + 2 - pf));
                        if (lowerBound > bestOverall + kScale * 0.5) continue;
                    }

                    for (int d2 = 0; d2 < 9; ++d2) {
                        if (d2 == d1) continue;
                        int cutoffK = -1;
                        bool abortWarn = (bestOverall < 0.0);
                        if (abortWarn) {
                            cutoffK = maxK;
                        } else if (!inside) {
                            if (res.scores[d1] < kHard) {
                                cutoffK = maxK;
                            } else {
                                int minSurv = static_cast<int>(std::floor(res.scores[d1] / kHard));
                                cutoffK = (scene.steps60 + 1) - minSurv;
                                if (cutoffK < 0) cutoffK = -1;
                            }
                        }
                        auto fullFast = planner_detail::continueAfterPivotSnap(
                            scene, preLasers, snFast, pK, d2, rawWorldDir, originUnsafe,
                            allowPickups, f60Fast, accel60Fast, maxK, cutoffK, abortWarn);
                        if (abortWarn && (fullFast.hasHard || fullFast.hasWarn)) continue;
                        if (!inside && fullFast.hasHard && cutoffK >= 0 && fullFast.firstHardK <= cutoffK) continue;
                        if (!inside && fullFast.hasHard) {
                            double lb = kHard * static_cast<double>(std::max(0, scene.steps60 + 2 - fullFast.firstHardK));
                            if (lb > res.scores[d1] + kScale * 0.5 && lb > bestOverall + kScale * 0.5) continue;
                        }
                        auto fullSlow = planner_detail::continueAfterPivotSnap(
                            scene, preLasers, snSlow, pK, d2, rawWorldDir, originUnsafe,
                            allowPickups, f60Slow, accel60Slow, maxK, cutoffK, abortWarn);
                        if (abortWarn && (fullSlow.hasHard || fullSlow.hasWarn)) continue;
                        if (!inside && fullSlow.hasHard && cutoffK >= 0 && fullSlow.firstHardK <= cutoffK) continue;
                        if (!fullFast.moved && !fullSlow.moved && d1 > 0) continue;
                        double ts = planner_detail::computeRolloutScore(
                            scene, fullFast, fullSlow, inside, d1, prevChosenWorld, rawWorldDir, true, bfsCache);
                        if (ts < res.scores[d1]) {
                            res.scores[d1] = ts;
                            if (ts < bestOverall) bestOverall = ts;
                            if (ts < bestStraightScore) {
                                res.usedTurn = true;
                            }
                        }
                    }
                }
            }
        };

        // First search active moving pivots (d1=1..8) so wait-then-move never procrastinates safe immediate escapes.
        searchTurnRange(1, 8);

        double bestMovingScore = 1e30;
        for (int d = 1; d < 9; ++d) {
            if ((res.blockedMask & (1 << d)) == 0 && res.scores[d] < bestMovingScore) {
                bestMovingScore = res.scores[d];
            }
        }
        // Only try delayed start (d1=0 -> move d2) when no immediate straight/turning route escapes cleanly.
        if (bestMovingScore > 0.0 && bestStraightScore > 0.0) {
            searchTurnRange(0, 0);
        }
    }

    // Pick lowest score unblocked direction; retain prevChosenWorld only within 64 space units in same tier
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
        if (diff > 0.0 && diff < 64.0 * 1024.0 &&
            std::floor(pScore / kScale) == std::floor(bestScore / kScale)) {
            bestDir = prevChosenWorld;
        }
    }

    res.bestDir = (bestDir == checkManual) ? -1 : bestDir;
    return res;
}

} // namespace iad
