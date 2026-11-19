-- Committed attacks the engine resolves without an entity collision the
-- sensor can see: Mom's door arm, bomb blasts and death explosions.
-- Each returns an area for main.lua's threat field, or nil. Optional
-- from/to bound the future updates in which the area is a hit.
local M = {}

-- Mom's door entities (45.0) reach out with "ArmOpen" while their collision
-- class stays 0. The 2026-10-30 session took all 7 of its hits on ArmOpen
-- frame 7, 12-76 units inward from the door and up to 26 to the side. Three
-- circles along the arm ({inward, radius}, plus the player's own size added
-- by the field) cover every recorded point by >=8 units without sealing the
-- whole doorway, so an escape stays reachable. B78YY60D added a hit 63
-- inward and 37 to the side: the tip circle widened from 20 to 30.
local ARM_HIT, ARM_LAST = 7, 12
local ARM = {{15, 24}, {40, 24}, {62, 30}}
function M.momArm(npc, room, out)
    if npc.Type ~= EntityType.ENTITY_MOM or npc.Variant ~= 0 then return end
    local sprite = npc:GetSprite()
    if sprite:GetAnimation() ~= "ArmOpen" then return end
    local f = sprite:GetFrame()
    if f > ARM_LAST then return end
    local inward = room:GetCenterPos() - npc.Position
    if inward:LengthSquared() < 1 then return end
    inward = inward:Normalized()
    for _, part in ipairs(ARM) do
        out[#out+1] = {position=npc.Position + inward*part[1], velocity=Vector(0,0),
            radius=part[2], from=math.max(0, ARM_HIT-1-f), to=ARM_LAST-f}
    end
end

-- Wormwood (62.3) surfaces with "Attack2" at a fixed spot (a grid centre)
-- and collides from frame 8 on; underground its collision class is 0, so
-- the contact model cannot see it coming. B78YY60D: both hits on frame 8,
-- the player 21-22 units from its centre. A hit at its body (the field adds
-- the player's size) for the updates around the surfacing.
local WORMWOOD, SURFACE_FRAME = 3, 8
function M.wormwood(npc, out)
    if npc.Type ~= EntityType.ENTITY_PIN or npc.Variant ~= WORMWOOD then return end
    local sprite = npc:GetSprite()
    if sprite:GetAnimation() ~= "Attack2" then return end
    local f = sprite:GetFrame()
    if f > SURFACE_FRAME then return end
    out[#out+1] = {position=npc.Position, velocity=Vector(0,0), radius=npc.Size+3,
        from=math.max(0, SURFACE_FRAME-1-f), to=SURFACE_FRAME+1-f}
end
-- Satan's foot (84.10) comes down with "Stomp": B78YY60D took 2 hearts on
-- frame 26 at 78 units centre to centre, the edge of the landing warning
-- (Size + 23). A hit of Size + 15 (plus the player's size) for frames 25-27.
local SATAN_FOOT, STOMP_FROM, STOMP_TO = 10, 25, 27
function M.satanStomp(npc, out)
    if npc.Type ~= EntityType.ENTITY_SATAN or npc.Variant ~= SATAN_FOOT then return end
    local sprite = npc:GetSprite()
    if sprite:GetAnimation() ~= "Stomp" then return end
    local f = sprite:GetFrame()
    if f > STOMP_TO then return end
    out[#out+1] = {position=npc.Position, velocity=Vector(0,0), radius=npc.Size+15,
        from=math.max(0, STOMP_FROM-1-f), to=STOMP_TO+1-f}
end

-- Grudge (877): sits still in ambush until the player enters a cardinal line,
-- then charges across at ~18/update (6LW23XWD f=238). Warn along clear cardinal
-- lanes while stationary so the player does not walk blindly across its trigger.
local GRUDGE_TYPE, PON_TYPE, MOTHER_TYPE, VIS_TYPE = 877, 840, 912, 39
local WHIPPER_TYPE, BEAST_TYPE = 834, 951
local CHUBBER_VARIANT, CHUBBER_WORM_VARIANT = 2, 22
local CHUBBER_MAX_REACH, CHUBBER_RETURN_SPEED, CHUBBER_TURN_SPEED, CHUBBER_MIN_DIST = 260, 13.5, 4.0, 24
local GRUDGE_AXES = {Vector(-1, 0), Vector(1, 0), Vector(0, -1), Vector(0, 1)}
local CHUBBER_ANGLES = {Horiz={0, 180}, Hori={0, 180}, Left={180}, Right={0}, Down={90}, Up={270}}
local function isNpcType(npc, key, rawId)
    local t = npc.Type
    local enumId = EntityType and EntityType[key]
    return t == rawId or (enumId ~= nil and t == enumId)
end
function M.isChubberWorm(npc)
    return isNpcType(npc, "ENTITY_VIS", VIS_TYPE) and npc.Variant == CHUBBER_WORM_VARIANT
end
-- Chubber (39.2) fires a tethered charger (39.22) instead of Brimstone during Attack03<dir>.
-- Keep the windup warning here so LaserHazards keeps excluding Chubber from hard beams.
function M.chubberWindup(npc, room, lasers)
    if not isNpcType(npc, "ENTITY_VIS", VIS_TYPE) or npc.Variant ~= CHUBBER_VARIANT then return end
    local sprite = npc.GetSprite and npc:GetSprite()
    if not sprite then return end
    local side = sprite:GetAnimation():match("^Attack03(%a+)$")
    local angles = side and CHUBBER_ANGLES[side]
    if not angles or (sprite:GetFrame() or 0) > 30 then return end
    for _, angle in ipairs(angles) do
        local dir = Vector(1, 0):Rotated(angle)
        local dist = CHUBBER_MAX_REACH
        if room and room.IsPositionInRoom then
            for step = 40, CHUBBER_MAX_REACH, 40 do
                if not room:IsPositionInRoom(npc.Position + dir * step, 0) then dist = step; break end
            end
        end
        if dist >= 40 then
            lasers[#lasers+1] = {origin=npc.Position, velocity=Vector(0,0),
                ring=false, width=16, points={Vector(0,0), dir * dist},
                reach=dist, angularSpeed=0, delay=0, warning=true}
        end
    end
end
-- Chubber's launched grub (39.22.0, Parent=39.2.0): StateFrame=0..42 (dies >42),
-- frac = 1 - sf/21; for frac >= 0 (or missing parent) vel = V1 * frac; on the
-- return leg (frac < 0) it pulls back to Parent via max(0,d-20)/d * toParent / max(1,43-sf) * (-frac).
function M.chubberWorm(npc, steps, areas, contactMargin)
    if not M.isChubberWorm(npc) then return end
    local cx, cy = npc.Position.X, npc.Position.Y
    local vx, vy = npc.Velocity.X, npc.Velocity.Y
    local speed = math.sqrt(vx*vx + vy*vy)
    local parent = npc.Parent or npc.SpawnerEntity
    local hasParent = parent and not (parent.IsDead and parent:IsDead()) and parent.Position ~= nil
    local px, py = hasParent and parent.Position.X or 0, hasParent and parent.Position.Y or 0
    local sf = npc.StateFrame
    if sf == nil or (sf == 0 and hasParent) then
        local ox, oy = cx - px, cy - py
        local dist = math.sqrt(ox*ox + oy*oy)
        if sf == nil then
            sf = (hasParent and dist > CHUBBER_MIN_DIST and (ox*vx + oy*vy) < 0) and 35 or 1
        elseif dist > CHUBBER_MIN_DIST and (ox*vx + oy*vy) < 0 then
            sf = 35
        end
    end
    if sf > 42 then return end
    local maxT = math.min(steps, 42 - sf)
    local f0 = 1 - sf / 21
    local v1 = npc.V1
    local v1x, v1y
    if v1 and (v1.X ~= 0 or v1.Y ~= 0) then
        v1x, v1y = v1.X, v1.Y
    elseif f0 > 0.05 then
        v1x, v1y = vx / f0, vy / f0
    else
        v1x, v1y = vx, vy
    end
    local pathX, pathY = {[0]=cx}, {[0]=cy}
    for t = 1, maxT do
        local nsf = sf + t
        local frac = 1 - nsf / 21
        if frac >= 0 or not hasParent then
            cx, cy = cx + v1x * frac, cy + v1y * frac
        else
            local dx, dy = px - cx, py - cy
            local d = math.sqrt(dx*dx + dy*dy)
            if d > 20 then
                local pull = (d - 20) / d / math.max(1, 43 - nsf) * (-frac)
                cx, cy = cx + dx * pull, cy + dy * pull
            end
        end
        pathX[t], pathY[t] = cx, cy
    end
    local size = npc.Size or 13
    local v1Spd = math.sqrt(v1x*v1x + v1y*v1y)
    local effSpeed = math.max(speed, sf >= 16 and math.max(8, v1Spd * 0.6) or 0)
    areas[#areas+1] = {position=npc.Position, velocity=Vector(0,0), pathX=pathX, pathY=pathY,
        from=0, to=maxT, radius=size + (contactMargin or 3)}
    if effSpeed > 0.5 then
        areas[#areas+1] = {position=npc.Position, velocity=Vector(0,0), pathX=pathX, pathY=pathY,
            from=0, to=maxT, radius=size + 5 + math.min(16, effSpeed * 2), warning=true}
    end
end
function M.grudge(npc, room, lasers)
    if not isNpcType(npc, "ENTITY_GRUDGE", GRUDGE_TYPE) or not npc:IsActiveEnemy(false) then return end
    if npc.Velocity:LengthSquared() >= 1 then return end
    local reach = 520
    local halfW = math.max(16, (npc.Size or 13) + 4)
    for _, dir in ipairs(GRUDGE_AXES) do
        local dist = reach
        if room and room.IsPositionInRoom then
            for step = 40, reach, 40 do
                if not room:IsPositionInRoom(npc.Position + dir * step, 0) then dist = step; break end
            end
        end
        if dist >= 40 then
            lasers[#lasers+1] = {origin=npc.Position, velocity=Vector(0,0),
                ring=false, width=halfW, points={Vector(0,0), dir * dist},
                reach=dist, angularSpeed=0, delay=0, warning=true}
        end
    end
end

-- Pon (840): fast-hopping enemy that bounces off walls; widen warning around
-- rapid movement or leaps.
function M.pon(npc, out)
    if not isNpcType(npc, "ENTITY_PON", PON_TYPE) or not npc:IsActiveEnemy(false) then return end
    local sprite = npc:GetSprite()
    local anim = sprite and sprite:GetAnimation():lower() or ""
    if npc.Velocity:LengthSquared() > 16 or (npc.SpriteOffset and npc.SpriteOffset.Y < -2) or
        anim:find("jump", 1, true) or anim:find("hop", 1, true) or anim:find("attack", 1, true) then
        out[#out+1] = {position=npc.Position + npc.Velocity * 1.5, velocity=npc.Velocity,
            radius=(npc.Size or 14) + 22, warning=true}
    end
end

-- Mother (912): Repentance Corpse II boss; Warn ahead of downward/horizontal
-- dashes and wide melee/knife animations (Spin/Slam/ThrowKnife/Appear).
function M.mother(npc, room, out)
    if not isNpcType(npc, "ENTITY_MOTHER", MOTHER_TYPE) or not npc:IsActiveEnemy(false) then return end
    local sprite = npc:GetSprite()
    local anim = sprite and sprite:GetAnimation():lower() or ""
    if anim:find("dash", 1, true) or anim:find("charge", 1, true) then
        local dir = npc.Velocity:LengthSquared() > 1 and npc.Velocity:Normalized() or Vector(0, 1)
        for d = 40, 200, 45 do
            out[#out+1] = {position=npc.Position + dir * d, velocity=npc.Velocity * 0.25,
                radius=math.max(36, (npc.Size or 28) + 8), warning=true}
        end
    elseif anim:find("slam", 1, true) or anim:find("fist", 1, true) or
        anim:find("knife", 1, true) or anim:find("spin", 1, true) then
        out[#out+1] = {position=npc.Position, velocity=npc.Velocity,
            radius=math.max(48, (npc.Size or 28) + 20), warning=true}
    end
end

-- Whipper / Snapper / Flagellant (834.0/1/2): extends a ~200px whip without
-- spawning a projectile or laser (CZTMRJ6J Hit #16 at 197px on AttackHori:9).
function M.whipper(npc, room, lasers)
    if not isNpcType(npc, "ENTITY_WHIPPER", WHIPPER_TYPE) or not npc:IsActiveEnemy(false) then return end
    local sprite = npc.GetSprite and npc:GetSprite()
    if not sprite then return end
    local anim = sprite:GetAnimation()
    local side = type(anim) == "string" and anim:match("^Attack(%a+)$")
    local angles = side and CHUBBER_ANGLES[side]
    local f = sprite:GetFrame() or 0
    if not angles or f > 15 then return end
    if (side == "Hori" or side == "Horiz") and sprite.FlipX ~= nil then
        angles = {sprite.FlipX and 180 or 0}
    end
    local activeFrom = math.max(1, 8 - f)
    for _, angle in ipairs(angles) do
        local dir = Vector(1, 0):Rotated(angle)
        local dist = 220
        if room and room.IsPositionInRoom then
            for step = 40, 220, 40 do
                if not room:IsPositionInRoom(npc.Position + dir * step, 0) then dist = math.max(80, step); break end
            end
        end
        lasers[#lasers+1] = {origin=npc.Position, velocity=npc.Velocity or Vector(0,0),
            ring=false, width=18, points={Vector(0,0), dir * dist},
            reach=dist, angularSpeed=0, delay=0, activeFrom=activeFrom}
    end
end

-- The Beast (951.0) SuckStart/SuckLoop suction pull + standoff warning
-- (CZTMRJ6J Hit #26-#28), and Ultra War Bomb (951.31) falling blast lead (#25).
function M.beast(npc, player, areas, lasers)
    if not isNpcType(npc, "ENTITY_THE_BEAST", BEAST_TYPE) then return 0, 0 end
    if npc.Variant == 0 then
        local sprite = npc.GetSprite and npc:GetSprite()
        local anim = sprite and sprite:GetAnimation()
        if type(anim) == "string" and anim:lower():find("suck", 1, true) then
            local extX, extY = 0, 0
            if player and player.Position then
                local dx, dy = npc.Position.X - player.Position.X, npc.Position.Y - player.Position.Y
                local dist = math.sqrt(dx*dx + dy*dy)
                if dist > 1 then
                    local pull = math.max(0.35, math.min(0.80, 125 / math.max(150, dist)))
                    extX, extY = dx / dist * pull, dy / dist * pull
                end
            end
            if lasers then
                local dirX = (npc.Position.X >= 320) and -1 or 1
                local reach = (npc.Size or 166) + 210
                lasers[#lasers+1] = {origin=npc.Position, velocity=Vector(0,0),
                    ring=false, width=160, points={Vector(0,0), Vector(dirX * reach, 0)},
                    reach=reach, angularSpeed=0, delay=0, warning=true}
            end
            return extX, extY
        end
    elseif npc.Variant == 31 and areas then
        local vel = npc.Velocity or Vector(0, 0)
        areas[#areas+1] = {position=npc.Position + vel * 1.5, velocity=Vector(vel.X, vel.Y + 3),
            radius=(npc.Size or 34) + 36, warning=true}
    end
    return 0, 0
end

-- Propagating FIRE_JET (1000.147) / FIRE_WAVE (1000.148) chains: each tile has
-- vel=(0,0) while new tiles spawn every ~2 updates 30px ahead (CZTMRJ6J Hit #12).
function M.fireWaves(jets, room, steps, areas)
    if not jets or #jets < 2 then return end
    local used = {}
    for i = 1, #jets do
        if not used[i] then
            local g0 = jets[i]
            local sp0 = g0.spawner
            local newest
            for j = i, #jets do
                local gj = jets[j]
                local same = sp0 and (gj.spawner == sp0) or
                    (not sp0 and not gj.spawner and gj.spawnerType == g0.spawnerType and
                     gj.pos:Distance(g0.pos) <= 200)
                if same then
                    used[j] = true
                    if not newest or gj.frame < newest.frame then newest = gj end
                end
            end
            if newest and newest.frame <= 8.5 then
                local prev, bestDf
                for j = 1, #jets do
                    local gj = jets[j]
                    if gj ~= newest then
                        local same = newest.spawner and (gj.spawner == newest.spawner) or
                            (not newest.spawner and not gj.spawner and gj.spawnerType == newest.spawnerType)
                        local df = gj.frame - newest.frame
                        if same and df >= 0.5 and df <= 8.0 then
                            local d = newest.pos:Distance(gj.pos)
                            if d >= 10 and d <= 80 and (not bestDf or df < bestDf) then
                                bestDf, prev = df, gj
                            end
                        end
                    end
                end
                if prev then
                    local vx = (newest.pos.X - prev.pos.X) / bestDf
                    local vy = (newest.pos.Y - prev.pos.Y) / bestDf
                    local spd = math.sqrt(vx*vx + vy*vy)
                    if spd >= 4 and spd <= 25 then
                        local waveTo = math.min(steps or 14, 12)
                        if room and room.IsPositionInRoom then
                            for t = 1, waveTo do
                                if not room:IsPositionInRoom(Vector(newest.pos.X + vx*t, newest.pos.Y + vy*t), 0) then
                                    waveTo = t; break
                                end
                            end
                        end
                        areas[#areas+1] = {position=newest.pos, velocity=Vector(vx, vy),
                            radius=math.max(35, newest.radius or 35), from=0, to=waveTo}
                    end
                end
            end
        end
    end
end

-- Every bomb blast in the 0.12.4-0.12.6 logs (normal and troll bombs) landed
-- on "Pulse" frame 58, 30-81 units from the bomb. Treat 78 * RadiusMultiplier
-- as a hit for the updates around detonation; the wider 100 envelope stays a
-- warning for the whole fuse.
local BLAST_FRAME, BLAST_RADIUS = 58, 78
-- Updates until detonation, or nil when the fuse is not readable.
local function detonation(bomb)
    local sprite = bomb:GetSprite()
    if sprite:GetAnimation() ~= "Pulse" then return nil end
    local at = BLAST_FRAME - sprite:GetFrame()
    return at >= -1 and at or nil
end
-- Rolling bombs keep x0.95 of their speed per update and move by their
-- current velocity (2026-11-04 IAD BOMB, ~10k samples of normal and troll
-- bombs); super troll bombs keep rolling at full speed.
local FRICTION = 0.95
local function friction(bomb)
    return BombVariant and bomb.Variant == BombVariant.BOMB_SUPERTROLL and 1 or FRICTION
end
-- Displacement after t updates.
function M.driftXY(bomb, t)
    local f = friction(bomb)
    local scale = f >= 1 and t or ((1 - f^t)/(1 - f))
    return bomb.Velocity.X * scale, bomb.Velocity.Y * scale
end
function M.drift(bomb, t)
    local f = friction(bomb)
    if f >= 1 then return bomb.Velocity*t end
    return bomb.Velocity*((1 - f^t)/(1 - f))
end
function M.bombBlast(bomb)
    local at = detonation(bomb)
    if not at then return nil end
    return {position=bomb.Position + M.drift(bomb, math.max(0, at)), velocity=Vector(0,0),
        radius=BLAST_RADIUS*bomb.RadiusMultiplier, from=math.max(0, at-1), to=at+1}
end
-- Chain knockback (2026-11-04 IAD BOMB, 1358 blast/bomb pairs): a bomb
-- inside a blast leaves at about PUSH_SPEED one update later and slows with
-- the same friction, so n updates on it has slid PUSH_SPEED*(1-0.95^n)/0.05
-- (median 73-90, up to 215 before walls). Its fuse runs on (no reset), so
-- SLACK only covers frame rounding. Mostly troll bombs were pushed; a
-- player's own bombs rarely, which stays on the safe side here. Blasts are
-- taken in detonation order, so a pushed bomb's swept blast pushes the next
-- one in turn. Only CHAIN_MAX are chained.
local CHAIN_MAX, PUSH_SPEED, SLACK = 8, 14, 1
local function slide(updates)
    if updates <= 0 then return 0 end
    return PUSH_SPEED*(1 - FRICTION^updates)/(1 - FRICTION)
end
local function closest(point, a, b)
    local d = b - a
    local length = d:LengthSquared()
    if length < 0.000001 then return a end
    local u = math.max(0, math.min(1, (point - a):Dot(d) / length))
    return a + d*u
end
function M.bombChain(bombs)
    local fused = {}
    for _, bomb in ipairs(bombs) do
        local area = M.bombBlast(bomb)
        if area then
            fused[#fused+1] = {bomb=bomb, at=detonation(bomb), area=area, sweep=Vector(0,0)}
        end
    end
    table.sort(fused, function(a, b) return a.at < b.at end)
    local chained = math.min(#fused, CHAIN_MAX)
    for i = 1, chained do
        local blast = fused[i]
        local from = blast.area.position
        local to = from + blast.sweep
        for j = i+1, chained do
            local other = fused[j]
            if other.at > blast.at then
                local where = other.bomb.Position + M.drift(other.bomb, math.max(0, blast.at)) + other.sweep
                local centre = closest(where, from, to)
                local away = where - centre
                local distance = slide(other.at - blast.at - 1)
                if distance > 0 and away:Length() <= blast.area.radius + other.bomb.Size then
                    if away:LengthSquared() < 1 then
                        other.area.radius = other.area.radius + distance
                    else
                        other.sweep = other.sweep + away:Normalized()*distance
                    end
                    other.pushed = true
                end
            end
        end
    end
    local areas = {}
    for _, entry in ipairs(fused) do
        local area = entry.area
        if entry.pushed then
            area.from, area.to = math.max(0, area.from-SLACK), area.to+SLACK
            if entry.sweep:LengthSquared() > 0 then area.sweep = entry.sweep end
        end
        areas[#areas+1] = area
    end
    return areas
end
-- Planning window needed to see every nearby detonation within limit.
function M.blastHorizon(entities, player, limit)
    local need = 0
    for _, entity in ipairs(entities) do
        local bomb = entity:ToBomb()
        if bomb and not bomb:IsDead() and bomb.ExplosionDamage > 0 then
            local at = detonation(bomb)
            if at and at+1 <= limit and bomb.Position:Distance(player.Position) <
                BLAST_RADIUS*bomb.RadiusMultiplier + 160 + bomb.Velocity:Length()*at then
                need = math.max(need, at+1)
            end
        end
    end
    return need
end

-- Enemies that explode where they die (bindingofisaacrebirth.wiki.gg):
-- normal, drowned and tainted boom flies, Mulliboom, Kamikaze and Holy
-- leeches, Black Maw, Ticking Spider, Poison Mind, Black Bony and Fly Bomb.
-- Red boom flies only shoot and sick ones leave gas: not explosions.
-- nil variant list = every variant.
local TAINTED_BOOMFLY = 6
local function kinds(list)
    local result = {}
    for name, variants in pairs(list) do
        if EntityType[name] then result[EntityType[name]] = variants end
    end
    return result
end
local exploders = kinds({
    ENTITY_BOOMFLY = {[0]=true, [2]=true, [TAINTED_BOOMFLY]=true},
    ENTITY_MULLIGAN = {[2]=true},
    ENTITY_LEECH = {[1]=true, [2]=true},
    ENTITY_BLACK_MAW = false,
    ENTITY_TICKING_SPIDER = false,
    ENTITY_POISON_MIND = false,
    ENTITY_BLACK_BONY = false,
    ENTITY_FLY_BOMB = false,
})
-- Exploders that run at the player instead of drifting.
local chasers = kinds({
    ENTITY_MULLIGAN = {[2]=true},
    ENTITY_LEECH = {[1]=true, [2]=true},
    ENTITY_BLACK_MAW = false,
    ENTITY_TICKING_SPIDER = false,
    ENTITY_POISON_MIND = false,
    ENTITY_FLY_BOMB = false,
})
local function listed(list, entity)
    local variants = list[entity.Type]
    if variants == nil then return false end
    return variants == false or variants[entity.Variant] == true
end
function M.exploder(entity) return listed(exploders, entity) end
function M.chaser(entity) return listed(chasers, entity) end
-- Logs 2026-10-26..11-02: 11 death explosions hit the player 36-82 units
-- (centre to centre) from the exploder. The field adds the player's size,
-- so 75 makes about 85 from a size-10 player a hit.
M.BURST_RADIUS = 75
M.TAINTED_BOOMFLY_RADIUS = 100
local function burstRadius(npc)
    if npc.Type == EntityType.ENTITY_BOOMFLY and npc.Variant == TAINTED_BOOMFLY then
        return M.TAINTED_BOOMFLY_RADIUS
    end
    return M.BURST_RADIUS
end

-- Closest distance during update t between two bodies whose relative
-- offset is (rx,ry) now and changes by (vx,vy) per update.
local function closestDuring(rx, ry, vx, vy, t)
    -- Relative offset at t-1 plus the update's motion; closest point on it.
    local ax, ay = rx + vx*(t-1), ry + vy*(t-1)
    local length = vx*vx + vy*vy
    local u = length > 0 and math.max(0, math.min(1, -(ax*vx + ay*vy)/length)) or 0
    local x, y = ax + vx*u, ay + vy*u
    return math.sqrt(x*x + y*y)
end
local function aloft(tear, t)
    if not tear.Height then return true end
    local height = tear.Height + (tear.FallingSpeed or 0)*t + 0.5*(tear.FallingAcceleration or 0)*t*t
    return height < -4
end
local function segmentGap(px, py, a, b)
    local dx, dy = b.X-a.X, b.Y-a.Y
    local x, y = px-a.X, py-a.Y
    local length = dx*dx + dy*dy
    local u = length > 0 and math.max(0, math.min(1, (x*dx + y*dy)/length)) or 0
    x, y = x-dx*u, y-dy*u
    return math.sqrt(x*x + y*y)
end
-- First future update in which the player side's tears (on arrival) and
-- beams (every update of contact) add up to the exploder's hit points, and
-- whether a beam decided it. Beam damage ticks are less certain in time.
local function killTime(npc, tears, beams, steps)
    local damage = {}
    for _, tear in ipairs(tears) do
        local rx, ry = tear.Position.X - npc.Position.X, tear.Position.Y - npc.Position.Y
        local vx, vy = tear.Velocity.X - npc.Velocity.X, tear.Velocity.Y - npc.Velocity.Y
        for t = 1, steps do
            if not aloft(tear, t) then break end
            if closestDuring(rx, ry, vx, vy, t) <= tear.Size + npc.Size then
                damage[t] = (damage[t] or 0) + tear.CollisionDamage
                break
            end
        end
    end
    local beamFrom
    for _, beam in ipairs(beams) do
        local last = (beam.Timeout or 0) > 0 and math.min(steps, beam.Timeout) or steps
        if beam.IsCircleLaser and beam:IsCircleLaser() then
            local r = beam.Radius or 0
            local follow = beam.Parent and not beam.DisableFollowParent and beam.Parent or nil
            local pos = follow and follow.Position or beam.Position
            local vel = (follow and follow.Velocity) or beam.Velocity
            local bvx, bvy = vel and vel.X or 0, vel and vel.Y or 0
            local reach = (npc.Size or 0) + (beam.Size or 0)
            for t = 1, last do
                local dx = npc.Position.X + npc.Velocity.X*t - (pos.X + bvx*t)
                local dy = npc.Position.Y + npc.Velocity.Y*t - (pos.Y + bvy*t)
                if math.abs(math.sqrt(dx*dx + dy*dy) - r) <= reach then
                    damage[t] = (damage[t] or 0) + beam.CollisionDamage
                    beamFrom = beamFrom or t
                end
            end
        else
            local a, b = beam.Position, beam:GetEndPoint()
            for t = 1, last do
                local x, y = npc.Position.X + npc.Velocity.X*t, npc.Position.Y + npc.Velocity.Y*t
                if segmentGap(x, y, a, b) <= npc.Size + beam.Size then
                    damage[t] = (damage[t] or 0) + beam.CollisionDamage
                    beamFrom = beamFrom or t
                end
            end
        end
    end
    local total = 0
    for t = 1, steps do
        total = total + (damage[t] or 0)
        if total >= npc.HitPoints then return t, beamFrom ~= nil and beamFrom <= t end
    end
    return nil
end
-- Death explosions for this update: a hit around the predicted death when a
-- killing shot is on its way, a warning when the exploder is one or two
-- player shots from death, nothing otherwise. Tainted boom flies also blast
-- a cross along the room; that shape is a warning, its delay is unknown.
-- Returns the predicted death update per exploder seed.
function M.deathBursts(npcs, tears, beams, player, steps, areas, lasers)
    local predicted = {}
    for _, npc in ipairs(npcs) do
        local radius = burstRadius(npc)
        local dead = npc.IsDead and npc:IsDead()
        if dead then
            local sprite = npc.GetSprite and npc:GetSprite()
            if sprite and sprite:GetAnimation() == "Explode" then
                local sf = sprite:GetFrame() or 0
                local rem = math.min(steps, math.max(1, 30 - sf))
                areas[#areas+1] = {position=npc.Position, velocity=Vector(0,0), radius=radius,
                    from=0, to=rem}
                if npc.Type == EntityType.ENTITY_BOOMFLY and npc.Variant == TAINTED_BOOMFLY and lasers then
                    local crossFrom = math.max(1, 25 - sf)
                    if crossFrom <= steps then
                        for _, angle in ipairs({0, 90, 180, 270}) do
                            lasers[#lasers+1] = {origin=npc.Position, velocity=Vector(0,0),
                                ring=false, width=24, points={Vector(0,0), Vector(600,0):Rotated(angle)},
                                reach=600, angularSpeed=0, delay=0, warning=true, activeFrom=crossFrom}
                        end
                    end
                end
            end
        else
            local t, beam = killTime(npc, tears, beams, steps)
            if t then
                predicted[npc.InitSeed] = t
                -- Arrival is exact to an update or two; beam ticks less so.
                local early, late = beam and 3 or 2, beam and 3 or 1
                areas[#areas+1] = {position=npc.Position, velocity=npc.Velocity, radius=radius,
                    from=math.max(0, t-early), to=t+late}
                if npc.Type == EntityType.ENTITY_BOOMFLY and npc.Variant == TAINTED_BOOMFLY and lasers then
                    for _, angle in ipairs({0, 90, 180, 270}) do
                        lasers[#lasers+1] = {origin=npc.Position + npc.Velocity*t, velocity=Vector(0,0),
                            ring=false, width=24, points={Vector(0,0), Vector(600,0):Rotated(angle)},
                            reach=600, angularSpeed=0, delay=0, warning=true, activeFrom=t}
                    end
                end
            elseif npc.HitPoints <= math.max(3.5, player.Damage*2) or M.chaser(npc) then
                -- A chaser explodes on reaching us whatever its health
                -- (2026-11-04: two 1-heart Leech hits), so it always warns.
                areas[#areas+1] = {position=npc.Position, velocity=npc.Velocity, radius=radius, warning=true}
            end
        end
    end
    return predicted
end
return M
