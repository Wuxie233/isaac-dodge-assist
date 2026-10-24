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
local MARGIN, BIAS_MAX = 2, 30
local function log(text) if Isaac and Isaac.DebugString then Isaac.DebugString(text) end end

function M.new()
    return {mode=0, targetSeed=nil, goalX=nil, goalY=nil, lastMove=1, tick=0,
        held=0, streak=0, quiet=0, bias=0, releaseLeft=0, releasedAt=nil, checkAt=nil,
        seen={}, scanTick=-10, knives={}, autoFireAt=nil, stalled=false,
        hint="tears", hintTick=-100, weapon="tears", laserReach=nil, info=nil}
end
function M.cycle(state)
    state.mode = (state.mode + 1) % 3
    state.targetSeed, state.goalX, state.goalY, state.held, state.info = nil, nil, nil, 0, nil
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
-- "charge": hold to charge, release to fire. "tap": a held button never
-- attacks (Spirit Sword charges its spin). Everything else fires while held.
local function weaponKind(player)
    if has(player, "HasWeaponType", WeaponType, {"WEAPON_SPIRIT_SWORD"}) then return "tap" end
    if has(player, "HasWeaponType", WeaponType, {"WEAPON_BRIMSTONE", "WEAPON_KNIFE", "WEAPON_MONSTROS_LUNGS", "WEAPON_TECH_X"}) or
        has(player, "HasCollectible", CollectibleType, {"COLLECTIBLE_CHOCOLATE_MILK", "COLLECTIBLE_CURSED_EYE", "COLLECTIBLE_NEPTUNUS"}) then
        return "charge"
    end
    return "tears"
end
local function laserWeapon(player)
    return has(player, "HasWeaponType", WeaponType, {"WEAPON_BRIMSTONE", "WEAPON_LASER", "WEAPON_TECH_X"})
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
    return a.Index == b.Index
end
local function ownedBy(e, player)
    local ok, spawner, parent = pcall(function() return e.SpawnerEntity, e.Parent end)
    return ok and (same(spawner, player) or same(parent, player))
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
    local seen, alive, fresh, beam, reach = state.seen, {}, 0, false, nil
    for _, e in ipairs(entities) do
        if ATTACKS[e.Type] and ownedBy(e, player) then
            local key = e.Index .. ":" .. e.InitSeed
            if e.Type == T.ENTITY_KNIFE then
                local knife = e.ToKnife and e:ToKnife()
                local flying = knife and knife.IsFlying and knife:IsFlying() or false
                if flying and continuous and not state.knives[key] then fresh = fresh + 1 end
                alive[key] = flying or nil
            else
                if continuous and not seen[key] then fresh = fresh + 1 end
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
    return fresh, beam, reach
end
local function hintSummary(player)
    local names = {}
    for _, name in ipairs({"WEAPON_TEARS", "WEAPON_BRIMSTONE", "WEAPON_LASER", "WEAPON_KNIFE", "WEAPON_BOMBS",
        "WEAPON_ROCKETS", "WEAPON_MONSTROS_LUNGS", "WEAPON_LUDOVICO_TECHNIQUE", "WEAPON_TECH_X", "WEAPON_SPIRIT_SWORD"}) do
        if has(player, "HasWeaponType", WeaponType, {name}) then names[#names+1] = name:sub(8) end
    end
    return table.concat(names, ",")
end

-- AUTO fire control. The item hint says whether a held button fires or
-- charges; what the game actually does overrides it: an attack during an
-- unbroken hold proves auto-fire, a long hold with nothing proves charging.
local function fireControl(state, ctx, p, aligned)
    local delay = ctx.queueDelay or 0
    local fresh, beam, reach = scanAttacks(state, ctx.entities, p)
    if reach then state.laserReach = reach end
    if state.tick - state.hintTick >= 15 then
        local hint = weaponKind(p)
        if hint ~= state.hint then log("IAD FIRE: hint=" .. hint .. " types=" .. hintSummary(p)) end
        state.hint, state.hintTick = hint, state.tick
    end
    local need = math.ceil(max(1, p.MaxFireDelay or 10)) + MARGIN + floor(state.bias)
    local afterRelease = state.releasedAt and state.tick - state.releasedAt <= 4 + delay
    if fresh > 0 and state.streak >= 3 + delay and not afterRelease then
        if not state.autoFireAt then log("IAD FIRE: holding fires (auto-fire)") end
        state.autoFireAt, state.stalled = state.tick, false
    end
    if state.streak > 0 and fresh == 0 then state.quiet = state.quiet + 1 elseif fresh > 0 then state.quiet = 0 end
    if not state.stalled and state.weapon == "tears" and state.quiet >= max(45, need*2) then
        state.stalled = true
        log("IAD FIRE: held " .. state.quiet .. " updates without an attack (charging)")
    end
    local kind = state.hint
    if kind ~= "tap" then
        if state.autoFireAt and state.tick - state.autoFireAt < 150 then kind = "tears"
        elseif kind == "charge" or state.stalled then kind = "charge" end
    end
    if kind ~= state.weapon then
        log("IAD FIRE: mode=" .. kind .. " need=" .. need .. " maxFireDelay=" .. string.format("%.2f", p.MaxFireDelay or -1))
        state.weapon, state.held, state.quiet = kind, 0, 0
    end
    -- Judge the last release: an attack within the queue delay + 3 updates.
    if state.checkAt then
        if fresh > 0 then
            log(string.format("IAD CHARGE: fired held=%d need=%d bias=%.1f", state.checkHeld, need, state.bias))
            state.bias, state.checkAt = max(0, state.bias - 0.5), nil
        elseif state.tick - state.checkAt > 3 + delay then
            state.bias = min(BIAS_MAX, state.bias + 3)
            log(string.format("IAD CHARGE: nothing held=%d need=%d bias=%.1f", state.checkHeld, need, state.bias))
            state.checkAt = nil
        end
    end
    local hold = true
    if kind == "tap" then
        hold = state.tick % 2 == 0
    elseif kind == "charge" then
        if state.releaseLeft > 0 then
            hold, state.releaseLeft = false, state.releaseLeft - 1
        elseif beam then
            state.held = 0 -- the next charge starts when the beam ends
        else
            state.held = state.held + 1
            if state.held >= need and aligned then
                -- Two updates released, so a 60Hz poll cannot miss it.
                hold, state.releaseLeft = false, 1
                state.releasedAt, state.checkAt, state.checkHeld, state.held = state.tick, state.tick, state.held, 0
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

-- Lead the target by the tear travel time plus the online input queue.
local function aim(player, target, queueDelay)
    local p, t, v = player.Position, target.Position, target.Velocity
    local distance = p:Distance(t)
    local tearSpeed = max(1, (player.ShotSpeed or 1) * 10)
    local lead = min(12, max(1.5, distance / tearSpeed)) + (queueDelay or 0)
    local dx, dy = t.X + v.X*lead - p.X, t.Y + v.Y*lead - p.Y
    local shoot, offset
    if abs(dx) >= abs(dy) then shoot, offset = dx >= 0 and 2 or 1, abs(dy)
    else shoot, offset = dy >= 0 and 4 or 3, abs(dx) end
    return shoot, offset <= target.Size + 10, t.X + v.X*lead, t.Y + v.Y*lead
end

local function pickTarget(state, player, enemies)
    local best, bestCost
    for _, e in ipairs(enemies) do
        local cost = e.Position:Distance(player.Position)
        if e.InitSeed == state.targetSeed then cost = cost * 0.7 - 20 end
        if not bestCost or cost < bestCost then best, bestCost = e, cost end
    end
    return best
end

-- Stand on the target's row or column at a comfortable distance with a
-- clear lane, close to us and away from the other enemies.
local function pickGoal(state, ctx, g, target, enemies, fromPlayer)
    local p, room = ctx.player, ctx.room
    -- Azazel's laser stops at MaxDistance; aim from inside it.
    local range = state.laserReach and min(state.laserReach, p.TearRange or 260) or p.TearRange or 260
    -- Closed-loop sim (8-tick queue): 0.8 of the range halved hits against
    -- 0.45 (5.8 -> 2.9 per minute) at about the same kill rate.
    local preferred = min(240, max(90, range*0.8))
    local tx, ty = target.Position.X, target.Position.Y
    local ignoreRocks = spectral(p) or laserWeapon(p)
    local best, bestCost, bx, by
    for pass = 1, 2 do
        for _, d in ipairs({preferred, preferred*0.75, min(preferred*1.3, range-20)}) do
            for _, o in ipairs({{d,0}, {-d,0}, {0,d}, {0,-d}}) do
                local x, y = tx + o[1], ty + o[2]
                local i = cellOf(room, g, x, y)
                local steps = i and fromPlayer[i]
                if steps and room:IsPositionInRoom(Vector(x, y), p.Size + 4) and
                    (pass == 2 or laneClear(room, g, x, y, tx, ty, ignoreRocks)) then
                    local cost = steps*40 + abs(d - preferred)*0.5
                    for _, e in ipairs(enemies) do
                        if e ~= target then
                            local gap = e.Position:Distance(Vector(x, y)) - e.Size
                            if gap < 90 then cost = cost + (90-gap)*3 end
                        end
                    end
                    if state.goalX and abs(state.goalX-x) + abs(state.goalY-y) < 30 then cost = cost - 50 end
                    if not bestCost or cost < bestCost then best, bestCost, bx, by = i, cost, x, y end
                end
            end
        end
        if best then break end
    end
    return best, bx, by
end

-- Endpoint after LOOK updates of full-speed walking, cut at the first
-- unsafe sample.
local function endpoint(ctx, dir, stride)
    local p = ctx.player.Position
    local x, y = p.X, p.Y
    local step = stride * LOOK / 4
    for _ = 1, 4 do
        local nx, ny = x + dir.X*step, y + dir.Y*step
        if not ctx.gridSafeXY(ctx.room, ctx.player, nx, ny) then break end
        x, y = nx, ny
    end
    return x, y
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
    local target = pickTarget(state, p, enemies)
    state.tick = state.tick + 1
    if not target then
        state.targetSeed, state.goalX, state.goalY, state.held, state.streak = nil, nil, nil, 0, 0
        return M.word(state.mode, nil, 0, false)
    end
    state.targetSeed = target.InitSeed
    local shoot, aligned, ax, ay = aim(p, target, ctx.queueDelay)
    local info = {targetX=target.Position.X, targetY=target.Position.Y, targetR=target.Size, aimX=ax, aimY=ay}
    state.info = info
    if state.mode == 1 then return M.word(1, nil, shoot, false) end

    local hold = fireControl(state, ctx, p, aligned)

    -- AUTO: movement.
    local g = grid(state, room, p, ctx.frame)
    local start = cellOf(room, g, p.Position.X, p.Position.Y)
    local costs = {}
    local goal, gx, gy
    if start then
        local fromPlayer = flood(g, start)
        goal, gx, gy = pickGoal(state, ctx, g, target, enemies, fromPlayer)
    end
    if goal then
        state.goalX, state.goalY = gx, gy
        info.goalX, info.goalY = gx, gy
        local field = flood(g, goal)
        for i, dir in ipairs(ctx.directions) do
            local x, y = endpoint(ctx, dir, ctx.stride)
            local cell = cellOf(room, g, x, y)
            local steps = cell and field[cell]
            costs[i] = steps and (steps*40 + sqrt((x-gx)^2 + (y-gy)^2)*0.35) or 1e6
        end
    else
        -- No reachable goal: keep distance from the target.
        state.goalX, state.goalY = nil, nil
        local t = target.Position
        for i, dir in ipairs(ctx.directions) do
            local x, y = endpoint(ctx, dir, ctx.stride)
            costs[i] = -sqrt((x-t.X)^2 + (y-t.Y)^2)
        end
    end
    local move = chooseMove(state, ctx, costs)
    if move then state.lastMove = move end
    return M.word(2, move and move-1, shoot, hold)
end

return M
