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
-- whole doorway, so an escape stays reachable.
local ARM_HIT, ARM_LAST = 7, 12
local ARM = {{15, 24}, {40, 24}, {62, 20}}
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
        local a, b = beam.Position, beam:GetEndPoint()
        local last = (beam.Timeout or 0) > 0 and math.min(steps, beam.Timeout) or steps
        for t = 1, last do
            local x, y = npc.Position.X + npc.Velocity.X*t, npc.Position.Y + npc.Velocity.Y*t
            if segmentGap(x, y, a, b) <= npc.Size + beam.Size then
                damage[t] = (damage[t] or 0) + beam.CollisionDamage
                beamFrom = beamFrom or t
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
        local t, beam = killTime(npc, tears, beams, steps)
        if t then
            predicted[npc.InitSeed] = t
            -- Arrival is exact to an update or two; beam ticks less so.
            local early, late = beam and 3 or 2, beam and 3 or 1
            areas[#areas+1] = {position=npc.Position, velocity=npc.Velocity, radius=M.BURST_RADIUS,
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
            areas[#areas+1] = {position=npc.Position, velocity=npc.Velocity, radius=M.BURST_RADIUS, warning=true}
        end
    end
    return predicted
end
return M
