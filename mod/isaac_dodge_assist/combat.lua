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
-- Charge release estimate (updates) adapts between these bounds.
local CHARGE_MIN, CHARGE_MAX = 4, 90

function M.new()
    return {mode=0, targetSeed=nil, goalX=nil, goalY=nil, lastMove=1, held=0,
        charge=20, released=nil, weaponFrame=-100, weapon="tears", info=nil}
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

-- Did the player's attack actually come out (for the charge estimate)?
local function shotSeen(entities, player)
    for _, e in ipairs(entities) do
        local source = e.SpawnerEntity or e.Parent
        if source and source.InitSeed == player.InitSeed then
            if (e.Type == EntityType.ENTITY_LASER or e.Type == EntityType.ENTITY_TEAR) and e.FrameCount <= 3 then return true end
            if e.Type == EntityType.ENTITY_KNIFE then
                local knife = e.ToKnife and e:ToKnife()
                if knife and knife.IsFlying and knife:IsFlying() then return true end
            end
        end
    end
    return false
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
    local range = p.TearRange or 260
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
    if not target then
        state.targetSeed, state.goalX, state.goalY, state.held = nil, nil, nil, 0
        return M.word(state.mode, nil, 0, false)
    end
    state.targetSeed = target.InitSeed
    local shoot, aligned, ax, ay = aim(p, target, ctx.queueDelay)
    local info = {targetX=target.Position.X, targetY=target.Position.Y, targetR=target.Size, aimX=ax, aimY=ay}
    state.info = info
    if state.mode == 1 then return M.word(1, nil, shoot, false) end

    -- AUTO: fire control.
    if ctx.frame - state.weaponFrame >= 15 then state.weapon, state.weaponFrame = weaponKind(p), ctx.frame end
    local hold = true
    if state.weapon == "charge" then
        if state.released then
            if shotSeen(ctx.entities, p) then
                state.charge, state.released = max(CHARGE_MIN, state.charge*0.92), nil
            elseif ctx.frame - state.released > 3 + (ctx.queueDelay or 0) then
                state.charge, state.released = min(CHARGE_MAX, state.charge*1.3 + 1), nil
            end
        end
        state.held = state.held + 1
        if state.held >= state.charge and aligned then
            hold, state.held, state.released = false, 0, ctx.frame
        end
    elseif state.weapon == "tap" then
        hold = ctx.frame % 2 == 0
    end

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
