-- Combat assist (F10 cycles OFF -> AIM -> AUTO).
-- AIM: shots you fire go toward the chosen target, with lead.
-- AUTO: while the room has enemies and your hands are off the keys, the
-- native host also walks and shoots; the dodge scores always come first.
-- Aim lead and the tear-lane rule follow isaac-jev (MIT,
-- https://github.com/chongchong59699/isaac-jev, localFireDirection and
-- clearTearLane): lead by the tear travel time, bounded to 1.5-12 updates,
-- quantized to four axes.
-- Output is one IAD2 word per packet (see M.word); this module never
-- touches input itself.
local M = {}
local abs, floor, max, min, sqrt = math.abs, math.floor, math.max, math.min, math.sqrt
local SCALE, HARD = 1048576, 1000000*1048576
M.MODES = {[0]="OFF", "AIM", "AUTO"}
local NO_MOVE = 15
-- Updates of full-speed walking used to compare directions against the goal.
local LOOK = 5
-- Charged attacks are full after ceil(MaxFireDelay) updates (wiki: Brimstone
-- charge = rounded-up tear delay / 30 s; Chocolate Milk and Monstro's Lung
-- fold their charge into the tear delay). MARGIN covers 60Hz/30Hz rounding;
-- bias grows when a release produced no attack.
local MARGIN, BIAS_MAX = 2, 16
local function log(text) if Isaac and Isaac.DebugString then Isaac.DebugString(text) end end

function M.new()
    return {mode=0, targetSeed=nil, goalX=nil, goalY=nil, lastMove=1, tick=0,
        held=0, streak=0, quiet=0, bias=0, releaseLeft=0, releasedAt=nil, checkAt=nil,
        seen={}, scanTick=-10, knives={}, autoFireAt=nil, provenAuto=false, stalled=false,
        targetSince=0, goalSide=nil, aimLogs=0, stats=nil,
        hint="tears", hintTick=-100, weapon="tears", laserReach=nil, info=nil}
end
-- Drop pending fire decisions and attack history when play is interrupted
-- (mode change, no target, room change). A held or released state from the
-- previous room must not fire, release, or bias the next charge.
local function clearAction(state)
    state.targetSeed, state.goalX, state.goalY, state.info = nil, nil, nil, nil
    state.held, state.streak, state.quiet = 0, 0, 0
    state.releaseLeft, state.releasedAt, state.checkAt, state.checkHeld = 0, nil, nil, nil
    state.beamWait, state.beamSeen = nil, nil
    state.seen, state.knives, state.scanTick = {}, {}, -10
    -- Proven auto-fire belongs to the build, not the room: 0.12.6 dropped it
    -- on every room change and re-learned it 83 times in one session,
    -- releasing and re-charging each time. Only a weapon change clears it.
    state.holdAttacks, state.stalled = 0, false
    state.goalSide = nil
    state.hintTick = -100
end
-- Another player is now ours: its weapon evidence and charge timing differ.
function M.forget(state)
    clearAction(state)
    state.bias, state.provenAuto, state.autoFireAt, state.hintTick = 0, false, nil, -100
end
function M.cycle(state)
    state.mode = (state.mode + 1) % 3
    clearAction(state)
    return state.mode
end

-- IAD2 word: bits 0-1 mode, 2-5 move (0-8 = IAD1 candidate index, 15 none),
-- 6-8 shoot (0 none, 1 left, 2 right, 3 up, 4 down), 9 hold fire.
function M.word(mode, move, shoot, hold)
    return mode | ((move or NO_MOVE) << 2) | ((shoot or 0) << 6) | (hold and 512 or 0)
end
function M.decode(word)
    local move = (word >> 2) & 15
    return word & 3, move ~= NO_MOVE and move or nil, (word >> 6) & 7, (word & 512) ~= 0
end

local function has(player, method, enum, names)
    if not enum then return false end
    for _, name in ipairs(names) do
        local value = enum[name]
        if value then
            local ok, present = pcall(player[method], player, value)
            if ok and present then return true end
        end
    end
    return false
end
-- Items that turn held tears into a charge. Neptunus is not one: held fire
-- shoots normally and it only charges while you are not firing.
local CHARGE_ITEMS = {"COLLECTIBLE_CHOCOLATE_MILK", "COLLECTIBLE_CURSED_EYE"}
-- "charge": hold to charge, release to fire. "tap": a held button never
-- attacks (Spirit Sword charges its spin). Everything else fires while held.
local function weaponKind(player)
    if has(player, "HasWeaponType", WeaponType, {"WEAPON_SPIRIT_SWORD"}) then return "tap" end
    if has(player, "HasWeaponType", WeaponType, {"WEAPON_BRIMSTONE", "WEAPON_KNIFE", "WEAPON_MONSTROS_LUNGS", "WEAPON_TECH_X"}) or
        has(player, "HasCollectible", CollectibleType, CHARGE_ITEMS) then
        return "charge"
    end
    return "tears"
end
local function laserWeapon(player)
    return has(player, "HasWeaponType", WeaponType, {"WEAPON_BRIMSTONE", "WEAPON_LASER", "WEAPON_TECH_X"})
end
-- Beams that arrive at once; Tech X rings fly like tears.
local function instantBeam(player)
    return has(player, "HasWeaponType", WeaponType, {"WEAPON_BRIMSTONE", "WEAPON_LASER"})
end
local function spectral(player)
    if not (TearFlags and TearFlags.TEAR_SPECTRAL) then return false end
    local ok, result = pcall(function()
        return player.TearFlags & TearFlags.TEAR_SPECTRAL == TearFlags.TEAR_SPECTRAL end)
    return ok and result == true
end

local function hostile(entity, playerOwned)
    local npc = entity:ToNPC()
    if not npc or npc:IsDead() or (entity.HitPoints or 1) <= 0 then return nil end
    if entity.Type == EntityType.ENTITY_FIREPLACE then return nil end
    if not npc:IsActiveEnemy(false) or (npc.IsVulnerableEnemy and not npc:IsVulnerableEnemy()) then return nil end
    if entity.EntityCollisionClass == EntityCollisionClass.ENTCOLL_NONE then return nil end
    if entity:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) or playerOwned(entity) then return nil end
    return npc
end

local function same(a, b)
    if not (a and b) then return false end
    if GetPtrHash then
        local ok, equal = pcall(function() return GetPtrHash(a) == GetPtrHash(b) end)
        if ok then return equal end
    end
    return a.Index == b.Index and
        (a.ControllerIndex == nil or b.ControllerIndex == nil or a.ControllerIndex == b.ControllerIndex)
end
local function ownedBy(e, player)
    -- Online co-op babies (player variant 9) may have both a spawner and a
    -- parent player. Check both branches: a same-controller main twin proves
    -- ownership, but any explicit remote-player link rejects it. In
    -- particular, do not let the spawner branch hide a remote Parent.
    local pending, known, hops, matched = {e}, {}, 0, false
    while #pending > 0 and hops < 12 do
        local source = table.remove(pending)
        if source and not known[source] then
            known[source] = true
            hops = hops + 1
            local ok, spawner, parent, kind, controller = pcall(function()
                return source.SpawnerEntity, source.Parent, source.Type, source.ControllerIndex
            end)
            if not ok then return false end
            if kind == EntityType.ENTITY_PLAYER then
                if controller ~= nil and player.ControllerIndex ~= nil and controller ~= player.ControllerIndex then
                    return false -- any remote-player link wins over a local one
                end
                if same(source, player) or
                    (controller ~= nil and player.ControllerIndex ~= nil and controller == player.ControllerIndex) then
                    matched = true
                end
            end
            if spawner then pending[#pending+1] = spawner end
            if parent then pending[#pending+1] = parent end
        end
    end
    return matched
end
local ATTACKS = {}
-- New attacks by this player since the last update (tears, lasers, bombs
-- from Dr. Fetus, knife throws), whether one of its lasers is still
-- active, and the length of a capped laser (Azazel).
local function scanAttacks(state, entities, player)
    local T = EntityType
    if not ATTACKS[T.ENTITY_TEAR] then
        ATTACKS = {[T.ENTITY_TEAR]=true, [T.ENTITY_LASER]=true, [T.ENTITY_BOMB]=true, [T.ENTITY_KNIFE]=true}
    end
    local continuous = state.scanTick == state.tick - 1
    local seen, alive, fresh, beam, reach, lasers = state.seen, {}, 0, false, nil, 0
    local newTear
    local counted = {}
    for _, e in ipairs(entities) do
        if ATTACKS[e.Type] and ownedBy(e, player) then
            local key = e.Index .. ":" .. e.InitSeed
            if e.Type == T.ENTITY_KNIFE then
                local knife = e.ToKnife and e:ToKnife()
                local flying = knife and knife.IsFlying and knife:IsFlying() or false
                if flying and continuous and not state.knives[key] then fresh = fresh + 1 end
                alive[key] = flying or nil
            else
                if continuous and not seen[key] and not counted[key] then
                    counted[key] = true
                    fresh = fresh + 1
                    if e.Type == T.ENTITY_LASER then
                        lasers = lasers + 1
                        -- A fresh beam shows how long it lasts and what it
                        -- deals per update: the payoff of the next ones.
                        local laser = e.ToLaser and e:ToLaser()
                        if laser and (laser.Timeout or 0) > 2 then state.beamTicks = min(30, laser.Timeout) end
                        if laser and (laser.CollisionDamage or 0) > 0 then state.beamDamage = laser.CollisionDamage end
                    end
                    if e.Type == T.ENTITY_TEAR and not newTear then newTear = e end
                end
                alive[key] = true
                if e.Type == T.ENTITY_LASER and not e:IsDead() then
                    beam = true
                    local laser = e.ToLaser and e:ToLaser()
                    local distance = laser and laser.MaxDistance or 0
                    if distance and distance > 0 then reach = distance end
                end
            end
        end
    end
    state.seen, state.knives, state.scanTick = alive, alive, state.tick
    return fresh, beam, reach, lasers, newTear
end
local function hintSummary(player)
    local names = {}
    for _, name in ipairs({"WEAPON_TEARS", "WEAPON_BRIMSTONE", "WEAPON_LASER", "WEAPON_KNIFE", "WEAPON_BOMBS",
        "WEAPON_ROCKETS", "WEAPON_MONSTROS_LUNGS", "WEAPON_LUDOVICO_TECHNIQUE", "WEAPON_TECH_X", "WEAPON_SPIRIT_SWORD"}) do
        if has(player, "HasWeaponType", WeaponType, {name}) then names[#names+1] = name:sub(8) end
    end
    for _, name in ipairs(CHARGE_ITEMS) do
        if has(player, "HasCollectible", CollectibleType, {name}) then names[#names+1] = name:sub(13) end
    end
    return table.concat(names, ",")
end

-- AUTO fire control. The item hint says whether a held button fires or
-- charges; what the game actually does overrides it: an attack during an
-- unbroken hold proves auto-fire, a long hold with nothing proves charging.
-- safe=false (a shot would blow an exploder up next to us) holds tears and
-- keeps a charge from releasing.
local function fireControl(state, ctx, p, aligned, safe)
    local delay = ctx.queueDelay or 0
    local fresh, beam, reach, lasers, newTear = scanAttacks(state, ctx.entities, p)
    if reach then state.laserReach = reach end
    if state.beamOut and not beam and state.beamDealt then
        -- One line per finished beam: what it actually dealt.
        log(string.format("IAD BEAM END: dealt=%.1f", state.beamDealt))
        if state.stats and state.beamDealt > 0 then state.stats.landed = state.stats.landed + 1 end
        state.beamDealt = nil
    end
    state.beamOut = beam
    if state.stats then state.stats.tears = state.stats.tears + fresh end
    -- Calibration for a later aim fix: does a tear inherit player motion?
    if newTear and state.aimLogs < 30 then
        state.aimLogs = state.aimLogs + 1
        local v, pv = newTear.Velocity or Vector(0, 0), p.Velocity or Vector(0, 0)
        log(string.format("IAD AIM: tear=%.2f,%.2f player=%.2f,%.2f shot=%d speed=%.2f",
            v.X, v.Y, pv.X, pv.Y, state.lastShoot or 0, p.ShotSpeed or -1))
    end
    if state.tick - state.hintTick >= 15 then
        local hint = weaponKind(p)
        if hint ~= state.hint then
            log("IAD FIRE: hint=" .. hint .. " types=" .. hintSummary(p))
            -- Evidence belongs to the weapon that produced it. Picking up
            -- Brimstone after tears must start charging immediately.
            state.autoFireAt, state.provenAuto, state.holdAttacks, state.held = nil, false, 0, 0
            state.laserReach = nil -- a capped beam's length belongs to that weapon
        end
        state.hint, state.hintTick = hint, state.tick
        state.brimstone = has(p, "HasWeaponType", WeaponType, {"WEAPON_BRIMSTONE"})
    end
    local need = math.ceil(max(1, p.MaxFireDelay or 10)) + MARGIN + floor(state.bias)
    local afterRelease = state.releasedAt and state.tick - state.releasedAt <= 4 + delay
    -- Auto-fire needs two attacks inside one unbroken hold. A Brimstone beam
    -- that shows up late after a release is not evidence (0.12.1 flipped
    -- Brimstone to auto-fire that way).
    local evidence = state.brimstone and fresh - lasers or fresh
    if state.streak == 0 then state.holdAttacks = 0 end
    if evidence > 0 and state.streak >= 3 + delay and not afterRelease then
        state.holdAttacks = (state.holdAttacks or 0) + evidence
        if state.holdAttacks >= 2 then
            if not state.provenAuto then log("IAD FIRE: holding fires (auto-fire)") end
            state.autoFireAt, state.provenAuto = state.tick, true
        end
    end
    if state.streak > 0 and fresh == 0 then state.quiet = state.quiet + 1
    elseif fresh > 0 then state.quiet, state.stalled = 0, false end
    if state.hint == "tears" and state.streak > 0 and state.quiet >= max(45, need*2) then
        -- A missing owner link must not turn ordinary tears into charged
        -- shots (0.12.2 did exactly that throughout a co-op baby run).
        -- Report the transition once: 0.12.6 repeated it every update.
        if not state.stalled then
            log("IAD FIRE: no owned attack observed for " .. state.quiet .. " updates; keeping tears")
        end
        state.stalled = true
    end
    local kind = state.hint
    if kind ~= "tap" then
        if state.provenAuto then kind = "tears"
        elseif kind == "charge" then kind = "charge" end
    end
    if kind ~= state.weapon then
        log("IAD FIRE: mode=" .. kind .. " need=" .. need .. " maxFireDelay=" .. string.format("%.2f", p.MaxFireDelay or -1))
        state.weapon, state.held, state.quiet = kind, 0, 0
    end
    -- Judge the last release: an attack within the queue delay + 3 updates.
    if state.checkAt then
        if fresh > 0 then
            log(string.format("IAD CHARGE: fired held=%d need=%d bias=%.1f", state.checkHeld, need, state.bias))
            state.bias, state.checkAt = max(0, state.bias - 1), nil
        elseif state.tick - state.checkAt > 3 + delay then
            -- Only a release right at the threshold says the charge was too
            -- short. 2026-11-02: ten misses in a row while bound to the
            -- wrong player drove the bias to 30 (mean 10.4 over 111
            -- charges), although holds of 70+ updates failed just the same.
            if state.checkHeld <= need + 2 then state.bias = min(BIAS_MAX, state.bias + 2) end
            log(string.format("IAD CHARGE: nothing held=%d need=%d bias=%.1f", state.checkHeld, need, state.bias))
            state.checkAt = nil
        end
    end
    -- Holding a charge only charges; its release is what fires.
    local hold = safe or kind == "charge"
    if kind == "tap" then
        hold = safe and state.tick % 2 == 0
    elseif kind == "charge" then
        if state.releaseLeft > 0 then
            hold, state.releaseLeft = false, state.releaseLeft - 1
        elseif state.brimstone and state.beamWait then
            -- Holding fire during the beam cuts its damage short: stay
            -- released until our beam has come and gone (or never came),
            -- plus one update.
            hold = false
            if beam then state.beamSeen = true
            elseif state.beamSeen or state.tick - state.beamWait > 4 + delay then
                state.beamWait, state.beamSeen = nil, nil
            end
        elseif beam then
            state.held = 0 -- the next charge starts when the beam ends
            if state.brimstone then hold = false end
        else
            state.held = state.held + 1
            if state.held >= need and aligned and safe then
                -- Two updates released, so a 60Hz poll cannot miss it.
                hold, state.releaseLeft = false, 1
                state.releasedAt, state.checkAt, state.checkHeld, state.held = state.tick, state.tick, state.held, 0
                state.beamWait = state.brimstone and state.tick or nil
                state.beamAxis = state.lastShoot
            end
        end
    end
    state.streak = hold and state.streak + 1 or 0
    return hold
end

-- Grid passability for walking and for tears, refreshed every 15 updates
-- (rocks and poop break during a fight).
local function grid(state, room, player, frame)
    local g = state.grid
    if g and g.room == room and frame - g.frame < 15 and g.flying == player.CanFly then return g end
    local width, size = room:GetGridWidth(), room:GetGridSize()
    g = {room=room, frame=frame, flying=player.CanFly, width=width, size=size, walk={}, shot={}}
    local C = GridCollisionClass
    for i = 0, size-1 do
        local c = room:GetGridCollision(i)
        g.walk[i] = c ~= C.COLLISION_WALL and c ~= C.COLLISION_SOLID and
            (player.CanFly or c == C.COLLISION_NONE or c == C.COLLISION_WALL_EXCEPT_PLAYER)
        g.shot[i] = c ~= C.COLLISION_WALL and c ~= C.COLLISION_SOLID and c ~= C.COLLISION_OBJECT
    end
    state.grid = g
    return g
end
local function cellOf(room, g, x, y)
    local i = room:GetGridIndex(Vector(x, y))
    if i < 0 or i >= g.size then return nil end
    return i
end
-- 8-neighbour BFS without corner cutting; distance in cells.
local function flood(g, start)
    local dist, queue, head = {[start]=0}, {start}, 1
    local w = g.width
    while head <= #queue do
        local i = queue[head]; head = head + 1
        local x, d = i % w, dist[i] + 1
        for oy = -1, 1 do for ox = -1, 1 do
            if ox ~= 0 or oy ~= 0 then
                local nx, j = x + ox, i + ox + oy*w
                if nx >= 0 and nx < w and j >= 0 and j < g.size and dist[j] == nil and g.walk[j] and
                    not (g.hazard and g.hazard[j]) and
                    (ox == 0 or oy == 0 or (g.walk[i+ox] and g.walk[i+oy*w])) then
                    dist[j] = d; queue[#queue+1] = j
                end
            end
        end end
    end
    return dist
end
local function laneClear(room, g, ax, ay, bx, by, ignoreRocks)
    if ignoreRocks then return true end
    local dx, dy = bx-ax, by-ay
    local length = sqrt(dx*dx + dy*dy)
    for s = 20, length - 20, 20 do
        local i = cellOf(room, g, ax + dx*s/length, ay + dy*s/length)
        if not i or not g.shot[i] then return false end
    end
    return true
end

-- Tears inherit about 1.3x the shooter's velocity: all of the sideways part,
-- and the forward part only when moving the way they fly (2026-11-02 IAD AIM
-- samples, 30 tears: sideways ratio median 1.3, nothing taken off when moving
-- backwards). AUTO walks while it shoots, so ignoring this sent tears wide.
local INHERIT = 1.3
local AXES = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}} -- shoot 1 left, 2 right, 3 up, 4 down
-- A beam (Brimstone, lasers) arrives at once and does not drift: aim at
-- where the target is when the queued release lands. It hits what overlaps
-- its width (about BEAM_HALF each side) up to its reach.
local BEAM_HALF = 12
-- A capped beam is only counted on an enemy it overlaps by half its size:
-- grazing the tip missed in the closed-loop sim whenever we drifted back.
local function inReach(forward, reach, size) return forward <= reach + size*0.5 end
local function aimBeam(player, target, delay, beam)
    local p, t, v = player.Position, target.Position, target.Velocity
    local pv = player.Velocity or Vector(0, 0)
    local ox, oy = p.X + pv.X*delay, p.Y + pv.Y*delay
    local px, py = t.X + v.X*delay, t.Y + v.Y*delay
    local best, bestMiss
    for shoot, axis in ipairs(AXES) do
        local forward = (px - ox)*axis[1] + (py - oy)*axis[2]
        if forward > 0 then
            local miss = abs((px - ox)*axis[2] - (py - oy)*axis[1])
            if not bestMiss or miss < bestMiss then best, bestMiss = shoot, miss end
        end
    end
    if not best then return 1, false, px, py end
    local reach = (px - ox)*AXES[best][1] + (py - oy)*AXES[best][2]
    return best, bestMiss <= target.Size + BEAM_HALF and inReach(reach, beam.reach, target.Size), px, py
end
-- For each shooting axis: lead the target by the tear's flight time plus the
-- online input queue, from where the queued command will actually fire, and
-- measure how far the drifting tear passes from it. Pick the closest pass.
-- beam = {reach=...} aims a beam instead.
local function aim(player, target, queueDelay, beam)
    local delay = queueDelay or 0
    if beam then return aimBeam(player, target, delay, beam) end
    local p, t, v = player.Position, target.Position, target.Velocity
    local pv = player.Velocity or Vector(0, 0)
    local ox, oy = p.X + pv.X*delay, p.Y + pv.Y*delay
    local tearSpeed = max(1, (player.ShotSpeed or 1) * 10)
    local best, bestMiss, bestX, bestY
    for shoot, axis in ipairs(AXES) do
        local ax, ay = axis[1], axis[2]
        local along = pv.X*ax + pv.Y*ay
        local speed = tearSpeed + INHERIT*max(0, along)
        local driftX, driftY = (pv.X - along*ax)*INHERIT, (pv.Y - along*ay)*INHERIT
        local time = min(12, max(1.5, t:Distance(Vector(ox, oy)) / speed))
        local px, py, forward
        for _ = 1, 2 do
            px, py = t.X + v.X*(time + delay), t.Y + v.Y*(time + delay)
            forward = (px - ox)*ax + (py - oy)*ay
            time = min(12, max(1.5, forward / speed))
        end
        if forward > 0 then
            -- Sideways offset of the target from the tear when it arrives.
            local sx, sy = px - ox - driftX*time, py - oy - driftY*time
            local miss = abs(sx*ay - sy*ax)
            if not bestMiss or miss < bestMiss then best, bestMiss, bestX, bestY = shoot, miss, px, py end
        end
    end
    if not best then
        local dx, dy = t.X - ox, t.Y - oy
        if abs(dx) >= abs(dy) then best = dx >= 0 and 2 or 1 else best = dy >= 0 and 4 or 3 end
        bestMiss, bestX, bestY = math.huge, t.X, t.Y
    end
    return best, bestMiss <= target.Size + 6, bestX, bestY
end
M.aim = aim -- exposed for tests

-- Nearest is the base cost. A blocked lane, being out of range and a fresh
-- target all cost extra; an enemy one or two shots from death costs less.
-- The current target is kept for DWELL updates unless another costs less
-- than half, then only for a clear (30%+20) improvement.
local DWELL = 30
-- A chasing exploder is best shot while it is still far away.
local CHASER_EARLY = 150
local function targetCost(state, player, e, g, room, ignoreRocks, chaser)
    local p, t = player.Position, e.Position
    local cost = t:Distance(p)
    local range = player.TearRange or 260
    if cost > range then cost = cost + (cost - range)*2 end
    if g and not laneClear(room, g, p.X, p.Y, t.X, t.Y, ignoreRocks) then cost = cost + 150 end
    if (e.HitPoints or 99) <= max(3.5, (player.Damage or 3.5)*2) then cost = cost - 60 end
    if chaser and chaser(e) and t:Distance(p) >= CHASER_EARLY then cost = cost - 40 end
    return cost
end
local function pickTarget(state, player, enemies, g, room, chaser)
    local ignoreRocks = spectral(player) or laserWeapon(player)
    local best, bestCost, current, currentCost
    for _, e in ipairs(enemies) do
        local cost = targetCost(state, player, e, g, room, ignoreRocks, chaser)
        if e.InitSeed == state.targetSeed then current, currentCost = e, cost end
        if not bestCost or cost < bestCost then best, bestCost = e, cost end
    end
    if current and best ~= current then
        local dwell = state.tick - (state.targetSince or 0) < DWELL
        local limit = dwell and currentCost*0.5 or currentCost*0.7 - 20
        if bestCost >= limit then return current end
    end
    return best
end

-- Our reach: Azazel's laser stops at MaxDistance.
local function attackRange(state, p)
    return state.laserReach and min(state.laserReach, p.TearRange or 260) or p.TearRange or 260
end
-- Death explosions hit 36-82 units from the exploder (logs 10-26..11-02).
-- A shot that would kill one must not land while it is that close: compare
-- where it and we will be when the tear arrives (a beam arrives at once).
-- A short beam (Azazel) cannot keep 110; it keeps what its reach allows.
local BURST_KEEP = 110
local function blastsUs(state, ctx, p, target)
    if not (ctx.exploder and ctx.exploder(target)) then return false end
    if (target.HitPoints or 99) > max(3.5, (p.Damage or 3.5)*2) then return false end
    local keep = min(BURST_KEEP, attackRange(state, p) - 10)
    local pv, tv = p.Velocity or Vector(0, 0), target.Velocity or Vector(0, 0)
    local time = 0
    if not laserWeapon(p) then
        time = min(12, target.Position:Distance(p.Position) / max(1, (p.ShotSpeed or 1)*10))
    end
    local dx = target.Position.X + tv.X*time - p.Position.X - pv.X*time
    local dy = target.Position.Y + tv.Y*time - p.Position.Y - pv.Y*time
    return dx*dx + dy*dy < keep*keep
end

-- Beam payoff (Brimstone hits everything in its path for its whole
-- duration): the damage a release along one axis from (ox,oy) deals, each
-- enemy capped at its health, in units of one full beam on one enemy.
-- Enemies move on at their velocity and the beam follows the player.
-- `unsafe` = it would kill an exploder within BURST_KEEP of us.
local BEAM_TICKS = 9
-- still=true: the beam leaves from a spot we stand on (goal planning).
local ZERO = {X=0, Y=0}
local function beamValue(state, ctx, p, enemies, shoot, ox, oy, from, step, still)
    local ticks, dmg = state.beamTicks or BEAM_TICKS, state.beamDamage or (p.Damage or 3.5)
    local reach = state.laserReach or math.huge
    local ax, ay = AXES[shoot][1], AXES[shoot][2]
    local pv = still and ZERO or p.Velocity or ZERO
    local exploder = ctx.exploder
    local total, hits, unsafe = 0, 0, false
    for _, e in ipairs(enemies) do
        local overlap, ev = 0, e.Velocity or Vector(0, 0)
        for k = 0, ticks-1, step or 1 do
            local t = from + k
            local fx = e.Position.X + ev.X*t - ox - pv.X*t
            local fy = e.Position.Y + ev.Y*t - oy - pv.Y*t
            local forward = fx*ax + fy*ay
            if forward > 0 and inReach(forward, reach, e.Size) and abs(fx*ay - fy*ax) <= e.Size + BEAM_HALF then
                overlap = overlap + (step or 1)
            end
        end
        if overlap > 0 then
            local health = e.HitPoints or dmg*ticks
            total, hits = total + min(health, dmg*min(overlap, ticks)), hits + 1
            if exploder and exploder(e) and dmg*overlap >= health and
                (e.Position.X - ox)^2 + (e.Position.Y - oy)^2 < BURST_KEEP^2 then unsafe = true end
        end
    end
    return total / (dmg*ticks), hits, unsafe
end
-- Best safe axis from (ox,oy) for a release `from` updates ahead.
local function bestBeam(state, ctx, p, enemies, ox, oy, from, step, still)
    local best, value, hits = nil, 0, 0
    for shoot = 1, 4 do
        local v, n, unsafe = beamValue(state, ctx, p, enemies, shoot, ox, oy, from, step, still)
        if not unsafe and v > value then best, value, hits = shoot, v, n end
    end
    return best, value, hits
end
-- Release now, or hold a full charge a little for more? Waiting pays when
-- within LOOKAHEAD updates the best axis is worth WAIT_GAIN times more (an
-- enemy walking into the line); never past WAIT_MAX updates of full charge.
local LOOKAHEAD, WAIT_GAIN, WAIT_MAX = 8, 1.25, 15
local function beamPlan(state, ctx, p, enemies)
    local delay = ctx.queueDelay or 0
    local pv = p.Velocity or Vector(0, 0)
    local shoot, value, hits = bestBeam(state, ctx, p, enemies, p.Position.X, p.Position.Y, delay)
    local later = 0
    for tau = 2, LOOKAHEAD, 2 do
        local _, v = bestBeam(state, ctx, p, enemies, p.Position.X, p.Position.Y, delay + tau, 2)
        later = max(later, v)
    end
    return {shoot=shoot, value=value, hits=hits, better=later >= value*WAIT_GAIN and later > value + 0.2}
end
M.beamPlan = beamPlan
-- Payoff of standing at (x,y) for a beam leaving `releaseIn` updates ahead.
function M.spotValue(state, ctx, p, enemies, x, y, releaseIn)
    local _, v = bestBeam(state, ctx, p, enemies, x, y, releaseIn, 1, true)
    return v
end

-- Stand on the target's row or column at a comfortable distance with a
-- clear lane, close to us and away from the other enemies. With a beam the
-- rows and columns of the two nearest other enemies compete too, and a spot
-- is worth more the more enemies its beam crosses. That is planned during
-- the charge for the moment it is full (state.releaseIn updates ahead):
-- enemies are taken where they will be then, and a spot we cannot reach by
-- then (plus the wait cap) counts half.
-- A short beam (Azazel, about 80) has to strike from close by. While it
-- charges, wait further out on the same line, as far as the rest of the
-- charge lets us walk back in (up to STANDOFF), so we close in only for the
-- release: 2026-11-05 took 5 of 6 hits standing 60 from the target.
local STANDOFF, APPROACH = 130, 0.7
local function pickGoal(state, ctx, g, target, enemies, fromPlayer)
    local p, room = ctx.player, ctx.room
    local range = attackRange(state, p)
    -- Closed-loop sim (8-tick queue): 0.8 of the range halved hits against
    -- 0.45 (5.8 -> 2.9 per minute) at about the same kill rate.
    -- 0.14: at least 120 away (90 put the player next to chasers).
    local preferred = min(240, max(120, range*0.8), max(60, range-20))
    -- Exploders (boom flies etc.) blew up 57-83 units from the player after
    -- being shot: kill them from outside the blast whenever range allows.
    local exploder = ctx.exploder or function() return false end
    -- Outside BURST_KEEP, so the killing shot is allowed from the goal; a
    -- chaser closes in while the shot flies, so engage it from further out.
    local chaser = ctx.chaser or function() return false end
    if exploder(target) then preferred = max(preferred, min(chaser(target) and 150 or 130, range-5)) end
    local ignoreRocks = spectral(p) or laserWeapon(p)
    local beam = state.beamGoals
    if beam and (not state.spotValues or state.spotRoom ~= room) then state.spotValues, state.spotRoom = {}, room end
    local anchors = {target}
    if beam then
        local others = {}
        for _, e in ipairs(enemies) do if e ~= target then others[#others+1] = e end end
        table.sort(others, function(a, b)
            return a.Position:Distance(p.Position) < b.Position:Distance(p.Position) end)
        for i = 1, min(2, #others) do anchors[#anchors+1] = others[i] end
    end
    local releaseIn = state.releaseIn or 0
    local extra = 0
    if beam and preferred < STANDOFF then
        extra = min(STANDOFF - preferred, APPROACH*(ctx.stride or 4)*max(0, releaseIn - 3))
    end
    local best, bestCost, bx, by, bestSide
    for pass = 1, 2 do
      for a, anchor in ipairs(anchors) do
        local tx, ty = anchor.Position.X, anchor.Position.Y
        if beam and a > 1 then
            -- Line up with where it will be at release.
            local v = anchor.Velocity or ZERO
            tx, ty = tx + v.X*releaseIn, ty + v.Y*releaseIn
        end
        for _, d in ipairs({preferred, preferred*0.75, min(preferred*1.3, range-20)}) do
            for side, o in ipairs({{1,0}, {-1,0}, {0,1}, {0,-1}}) do
                side = side + (a-1)*4
                -- The strike spot (x,y) and, while charging, the waiting
                -- spot behind it; near a wall wait less far out.
                local x, y = tx + o[1]*d, ty + o[2]*d
                local i, steps, wx, wy
                for _, back in ipairs({extra, extra*0.5, 0}) do
                    wx, wy = x + o[1]*back, y + o[2]*back
                    i = cellOf(room, g, wx, wy)
                    steps = i and fromPlayer[i]
                    if steps and room:IsPositionInRoom(Vector(wx, wy), p.Size + 4) then break end
                    steps = nil
                    if back == 0 then break end
                end
                if steps and (pass == 2 or laneClear(room, g, x, y, tx, ty, ignoreRocks)) then
                    local cost = steps*40 + abs(d - preferred)*0.5
                    if beam then
                        -- Another enemy's line must be clearly better to win.
                        -- Cached per 20-unit spot for a few updates: the
                        -- candidates move with the enemies every update.
                        local key = (floor(releaseIn/4)*100000 + floor(x/20))*1000 + floor(y/20)
                        local cached = state.spotValues[key]
                        if not cached or state.tick - cached[1] >= 6 then
                            local _, v = bestBeam(state, ctx, p, enemies, x, y, releaseIn, 3, true)
                            cached = {state.tick, v}
                            state.spotValues[key] = cached
                        end
                        local value = cached[2]
                        local arrive = sqrt((x - p.Position.X)^2 + (y - p.Position.Y)^2) / max(1, ctx.stride or 4)
                        if arrive > releaseIn + WAIT_MAX then value = value*0.5 end
                        cost = cost - 80*value + (a > 1 and 30 or 0)
                    end
                    for _, e in ipairs(enemies) do
                        if e ~= target then
                            local gap = e.Position:Distance(Vector(wx, wy)) - e.Size
                            -- Mulliboom and leeches run at us: more room.
                            local keep = chaser(e) and 150 or exploder(e) and 130 or 110
                            if gap < keep then cost = cost + (keep-gap)*5 end
                        end
                    end
                    if state.goalX and abs(state.goalX-wx) + abs(state.goalY-wy) < 30 then cost = cost - 50 end
                    -- Circling to the other side of the same target is what
                    -- made AUTO run around: it must be clearly better. 60 (not
                    -- 120) keeps the simulated chaser hits at the 0.13 level.
                    if state.goalSide and side ~= state.goalSide then cost = cost + 60 end
                    if not bestCost or cost < bestCost then best, bestCost, bx, by, bestSide = i, cost, wx, wy, side end
                end
            end
        end
      end
      if best then break end
    end
    return best, bx, by, bestSide
end

-- While our beam is out it moves with us along a fixed axis. Keep the
-- enemy it hits best on it: step across with it and hold the distance
-- (inside the reach of a short beam). Nil when the beam reaches none.
local function trackBeam(state, ctx, enemies)
    local axis = AXES[state.beamAxis or 0]
    if not axis then return nil end
    local p = ctx.player.Position
    local reach = state.laserReach or math.huge
    local delay = ctx.queueDelay or 0
    local best, bestMiss, bx, by
    for _, e in ipairs(enemies) do
        local v = e.Velocity or ZERO
        local x, y = e.Position.X + v.X*delay, e.Position.Y + v.Y*delay
        local forward = (x - p.X)*axis[1] + (y - p.Y)*axis[2]
        local miss = abs((x - p.X)*axis[2] - (y - p.Y)*axis[1])
        if forward > 0 and forward <= reach + e.Size and miss <= e.Size + BEAM_HALF + 40 and
            (not bestMiss or miss < bestMiss) then
            local keep = max(20, min(forward, reach*0.8))
            best, bestMiss, bx, by = e, miss, x - axis[1]*keep, y - axis[2]*keep
        end
    end
    return best, bx, by
end

-- Endpoint after LOOK updates of full-speed walking, cut at the first
-- unsafe sample, and whether the walk crosses a hazard cell.
local function endpoint(ctx, g, dir, stride)
    local p = ctx.player.Position
    local x, y = p.X, p.Y
    local step = stride * LOOK / 4
    local crossed = false
    for _ = 1, 4 do
        local nx, ny = x + dir.X*step, y + dir.Y*step
        if not ctx.gridSafeXY(ctx.room, ctx.player, nx, ny) then break end
        x, y = nx, ny
        local i = g.hazard and cellOf(ctx.room, g, x, y)
        if i and g.hazard[i] then crossed = true end
    end
    return x, y, crossed
end

-- Dodge first: walk toward the goal only through directions with the best
-- available risk class (safe, then warning-only); with a real collision
-- ahead, take the native choice outright.
local function chooseMove(state, ctx, costs)
    local scores, blocked = ctx.scores, ctx.blocked or 0
    local function open(i) return (blocked & (1 << (i-1))) == 0 end
    local least
    if scores then
        for i = 1, 9 do if open(i) and (not least or scores[i] < least) then least = scores[i] end end
    end
    local limit
    if not least or least <= 0 then limit = 0
    elseif least < HARD then limit = least + 500*SCALE
    else
        for i = 1, 9 do if open(i) and scores[i] == least then return i end end
    end
    local best, bestCost
    for i = 1, 9 do
        local score = scores and scores[i] or 0
        if open(i) and score <= limit then
            local cost = costs[i]
            if score < 0 then cost = cost + (score + SCALE) / 1024 * 0.1 end
            if i == state.lastMove then cost = cost - 6 end
            if not bestCost or cost < bestCost then best, bestCost = i, cost end
        end
    end
    return best
end

-- Taking damage drops a charge in progress: 2026-11-05, every release after
-- a hit during the charge (3 of 3) produced nothing at the usual hold.
-- Count it again from zero instead of releasing early and raising the bias.
function M.hurt(state)
    if state.weapon == "charge" and state.brimstone and state.held > 0 then
        log(string.format("IAD CHARGE: hit restarts held=%d", state.held))
        state.held = 0
    end
end

-- Per-room AUTO summary (IAD COMBAT STATS), flushed by main.lua.
function M.stats(state)
    if not state.stats then
        state.stats = {ticks=0, firing=0, aligned=0, switches=0, retargets=0, sides=0, distance=0, tears=0, dealt=0,
            beams=0, landed=0}
    end
    return state.stats
end
function M.flushStats(state, reason)
    local s = state.stats
    state.stats = nil
    if not s or s.ticks == 0 then return end
    log(string.format("IAD COMBAT STATS: ticks=%d firing=%.0f%% aligned=%.0f%% switches=%d retargets=%d sides=%d meanDist=%.0f tears=%d dealt=%.1f beams=%d landed=%d reason=%s",
        s.ticks, s.firing*100/s.ticks, s.aligned*100/s.ticks, s.switches, s.retargets, s.sides, s.distance/s.ticks, s.tears, s.dealt,
        s.beams, s.landed, reason))
end
-- Damage taken by an enemy (core's damage callback): counted for the AUTO
-- stats when one of our own attacks dealt it.
function M.dealt(state, player, source, amount)
    local s, e = state.stats, source and source.Entity
    if s and state.mode == 2 and e and ownedBy(e, player) then
        s.dealt = s.dealt + amount
        if state.beamDealt then state.beamDealt = state.beamDealt + amount end
    end
end

-- ctx: player, room, frame, entities, playerOwned, gridSafeXY, directions,
-- stride (full-speed displacement per update), queueDelay (updates),
-- scores/blocked (nil when nothing threatens). Returns the IAD2 word.
function M.update(state, ctx)
    state.info = nil
    if state.mode == 0 then return 0 end
    local p, room = ctx.player, ctx.room
    local enemies = {}
    for _, e in ipairs(ctx.entities) do
        local npc = hostile(e, ctx.playerOwned)
        if npc then enemies[#enemies+1] = npc end
    end
    local g = grid(state, room, p, ctx.frame)
    g.hazard = ctx.hazardCells
    state.tick = state.tick + 1
    local previousSeed = state.targetSeed
    local target = pickTarget(state, p, enemies, g, room, ctx.chaser)
    if not target then
        clearAction(state)
        return M.word(state.mode, nil, 0, false)
    end
    local stats = state.mode == 2 and M.stats(state) or nil
    if target.InitSeed ~= previousSeed then
        state.targetSince, state.goalSide = state.tick, nil
        if stats and previousSeed then
            stats.switches = stats.switches + 1
            -- Leaving a target that is still alive is a retarget, not a kill.
            for _, e in ipairs(enemies) do
                if e.InitSeed == previousSeed then stats.retargets = stats.retargets + 1 break end
            end
        end
    end
    state.targetSeed = target.InitSeed
    -- Beams ignore the tear range; only a capped beam (Azazel) stops short.
    local beam = instantBeam(p) and {reach=state.laserReach or math.huge} or nil
    local shoot, aligned, ax, ay = aim(p, target, ctx.queueDelay, beam)
    local info = {targetX=target.Position.X, targetY=target.Position.Y, targetR=target.Size, aimX=ax, aimY=ay}
    state.info = info
    if state.mode == 1 then state.lastShoot = shoot; return M.word(1, nil, shoot, false) end

    -- A charged Brimstone release goes where it pays most, not just at the
    -- target, and holds a little when an enemy is about to walk in.
    local safe = not blastsUs(state, ctx, p, target)
    state.beamGoals = beam ~= nil and has(p, "HasWeaponType", WeaponType, {"WEAPON_BRIMSTONE"})
    local plan
    local need = math.ceil(max(1, p.MaxFireDelay or 10)) + MARGIN + floor(state.bias)
    -- Only the release needs the plan: from two updates before full charge.
    if state.beamGoals and state.held + 3 >= need then
        plan = beamPlan(state, ctx, p, enemies)
        if plan.shoot then
            local waited = state.held + 1 - need
            shoot, safe = plan.shoot, true
            aligned = not plan.better or waited >= WAIT_MAX
            info.beamValue, info.beamHits = plan.value, plan.hits
        else
            aligned = false -- nothing worth a beam (or only an exploder next to us)
        end
    end
    state.lastShoot = shoot
    local wasHeld = state.held
    local hold = fireControl(state, ctx, p, aligned, safe)
    -- Updates until the next beam can leave: the rest of the charge (a full
    -- one while a beam is out or just released), plus the online queue.
    state.releaseIn = max(0, need - state.held) + (ctx.queueDelay or 0)
    if plan and plan.shoot and state.releasedAt == state.tick then
        log(string.format("IAD BEAM: value=%.2f hits=%d waited=%d shoot=%d dist=%.0f reach=%.0f", plan.value, plan.hits,
            wasHeld + 1 - need, plan.shoot, target.Position:Distance(p.Position), state.laserReach or -1))
        state.beamDealt = 0
        if stats then stats.beams = stats.beams + 1 end
    end
    stats.ticks, stats.distance = stats.ticks + 1, stats.distance + target.Position:Distance(p.Position)
    if hold then stats.firing = stats.firing + 1 end
    if aligned then stats.aligned = stats.aligned + 1 end

    -- AUTO: movement.
    local start = cellOf(room, g, p.Position.X, p.Position.Y)
    local costs = {}
    local goal, gx, gy, side
    local tracked
    if start and state.beamGoals and state.beamOut then
        local x, y
        tracked, x, y = trackBeam(state, ctx, enemies)
        local i = tracked and cellOf(room, g, x, y)
        if i and g.walk[i] and not (g.hazard and g.hazard[i]) and room:IsPositionInRoom(Vector(x, y), p.Size + 4) then
            goal, gx, gy, side = i, x, y, state.goalSide
        end
    end
    if start and not goal then
        local fromPlayer = flood(g, start)
        goal, gx, gy, side = pickGoal(state, ctx, g, target, enemies, fromPlayer)
    end
    if goal then
        if state.goalSide and side ~= state.goalSide then stats.sides = stats.sides + 1 end
        state.goalSide = side
        state.goalX, state.goalY = gx, gy
        info.goalX, info.goalY = gx, gy
        local field = flood(g, goal)
        for i, dir in ipairs(ctx.directions) do
            local x, y, crossed = endpoint(ctx, g, dir, ctx.stride)
            local cell = cellOf(room, g, x, y)
            local steps = not crossed and cell and field[cell]
            costs[i] = steps and (steps*40 + sqrt((x-gx)^2 + (y-gy)^2)*0.35) or 1e6
        end
    else
        -- No reachable goal: keep distance from the target.
        state.goalX, state.goalY = nil, nil
        local t = target.Position
        for i, dir in ipairs(ctx.directions) do
            local x, y, crossed = endpoint(ctx, g, dir, ctx.stride)
            costs[i] = -sqrt((x-t.X)^2 + (y-t.Y)^2) + (crossed and 1e6 or 0)
        end
    end
    -- Tears inherit sideways motion, so while firing, walking across the
    -- shot costs. Simulated AUTO with the measured 1.3 inheritance: weight 20
    -- raised kills 5-24% with no scenario taking more hits (30-60 killed more
    -- but took more hits from flies).
    if hold and shoot >= 1 and shoot <= 4 then
        local axis = AXES[shoot]
        for i, dir in ipairs(ctx.directions) do
            costs[i] = costs[i] + 20*abs(dir.X*axis[2] - dir.Y*axis[1])
        end
    end
    local move = chooseMove(state, ctx, costs)
    if move then state.lastMove = move end
    return M.word(2, move and move-1, shoot, hold)
end

return M
