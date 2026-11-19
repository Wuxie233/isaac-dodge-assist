local EscapeSpace = {}
local NEIGHBORS = {{-1,0},{1,0},{0,-1},{0,1}}
local DEPTH = 4
local math_min, math_max, math_sqrt, math_floor = math.min, math.max, math.sqrt, math.floor

-- One context per decision update. Geometry, enemy forecasts and local flood
-- results are shared by every straight/turning candidate in that update.
-- safeFn accepts either gridSafeXY(room, player, x, y) or gridSafe(room, player, Vector(x, y)).
function EscapeSpace.build(room, player, contacts, steps, forecast, safeFn, isXY)
    local width, size = room:GetGridWidth(), room:GetGridSize()
    local ox, oy, sx, sy = 0, 0, 0, 0
    if room.GetGridPosition and width > 1 and size > width then
        local p0, p1, pw = room:GetGridPosition(0), room:GetGridPosition(1), room:GetGridPosition(width)
        ox, oy = p0.X, p0.Y
        sx, sy = p1.X - ox, pw.Y - oy
    end
    local context = {room=room, player=player, safe=safeFn, isXY=isXY == true,
        width=width, size=size, ox=ox, oy=oy, sx=sx, sy=sy,
        nodes={}, costs={}, edges={}, queue={}, depths={}, seen={}, stamp=0,
        enemies={}, count=0}
    local pr = player.Size
    for _, enemy in ipairs(contacts) do
        local radius = pr + enemy.Size + 7
        local p0, p1 = forecast(enemy, steps), forecast(enemy, steps + 4)
        context.count = context.count + 1
        context.enemies[context.count] = {
            x0=p0.X, y0=p0.Y, x1=p1.X, y1=p1.Y, radius=radius, rsq=radius*radius}
    end
    return context
end

local function isSafe(context, x, y)
    if context.isXY then return context.safe(context.room, context.player, x, y) end
    return context.safe(context.room, context.player, Vector(x, y))
end

local function node(context, index)
    if index < 0 or index >= context.size then return nil end
    local cached = context.nodes[index]
    if cached ~= nil then return cached or nil end
    local px, py
    if context.sx > 0 and context.sy > 0 then
        px = context.ox + (index % context.width) * context.sx
        py = context.oy + math_floor(index / context.width) * context.sy
    else
        local position = context.room:GetGridPosition(index)
        px, py = position.X, position.Y
    end
    if not isSafe(context, px, py) then
        context.nodes[index] = false
        return nil
    end
    local clearance = 100
    for i = 1, context.count do
        local enemy = context.enemies[i]
        local d0x, d0y = px - enemy.x0, py - enemy.y0
        local d1x, d1y = px - enemy.x1, py - enemy.y1
        local distance = math_min(math_sqrt(d0x*d0x + d0y*d0y), math_sqrt(d1x*d1x + d1y*d1y)) - enemy.radius
        if distance < clearance then
            clearance = distance
            if clearance <= 0 then
                context.nodes[index] = false
                return nil
            end
        end
    end
    cached = {x=px, y=py, clearance=clearance}
    context.nodes[index] = cached
    return cached
end

local function edgeClear(enemy, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local length = dx*dx + dy*dy
    local rsq = enemy.rsq
    if length == 0 then
        local d0x, d0y = enemy.x0 - ax, enemy.y0 - ay
        if d0x*d0x + d0y*d0y <= rsq then return false end
        local d1x, d1y = enemy.x1 - ax, enemy.y1 - ay
        return d1x*d1x + d1y*d1y > rsq
    end
    local t0 = math_max(0, math_min(1, ((enemy.x0 - ax)*dx + (enemy.y0 - ay)*dy) / length))
    local ex0, ey0 = enemy.x0 - ax - dx*t0, enemy.y0 - ay - dy*t0
    if ex0*ex0 + ey0*ey0 <= rsq then return false end
    local t1 = math_max(0, math_min(1, ((enemy.x1 - ax)*dx + (enemy.y1 - ay)*dy) / length))
    local ex1, ey1 = enemy.x1 - ax - dx*t1, enemy.y1 - ay - dy*t1
    return ex1*ex1 + ey1*ey1 > rsq
end

local function neighbor(context, index, direction)
    local x = index % context.width + direction[1]
    if x < 0 or x >= context.width then return nil end
    local nextIndex = index + direction[1] + direction[2]*context.width
    local current, nextNode = node(context, index), node(context, nextIndex)
    if not current or not nextNode then return nil end
    local lo, hi = index < nextIndex and index or nextIndex, index < nextIndex and nextIndex or index
    local edgeKey = lo * context.size + hi
    local connected = context.edges[edgeKey]
    if connected == nil then
        connected = isSafe(context, (current.x + nextNode.x)*0.5, (current.y + nextNode.y)*0.5)
        if connected then
            for i = 1, context.count do
                if not edgeClear(context.enemies[i], current.x, current.y, nextNode.x, nextNode.y) then
                    connected = false
                    break
                end
            end
        end
        context.edges[edgeKey] = connected
    end
    if connected then return nextIndex end
end

local function spaceCost(context, index)
    if context.costs[index] then return context.costs[index] end
    local queue, depths, seen = context.queue, context.depths, context.seen
    local stamp = context.stamp + 1
    context.stamp = stamp
    queue[1], depths[1], seen[index] = index, 0, stamp
    local head, tail, exits, reach = 1, 1, 0, 0
    while head <= tail do
        local current, depth = queue[head], depths[head]
        head = head + 1
        -- A bounded four-connected flood: at most 41 nodes per endpoint.
        -- A narrow entrance cannot borrow open cells across a wall or enemy.
        reach = reach + 1
        if depth < DEPTH then
            for d = 1, 4 do
                local nextIndex = neighbor(context, current, NEIGHBORS[d])
                if nextIndex then
                    if depth == 0 then exits = exits + 1 end
                    if seen[nextIndex] ~= stamp then
                        seen[nextIndex] = stamp
                        tail = tail + 1
                        queue[tail], depths[tail] = nextIndex, depth + 1
                    end
                end
            end
        end
    end
    local result = (41 - reach)*12 + (4 - exits)*70
    context.costs[index] = result
    return result
end

-- This is a tie-break cost, never a damage score or a reason to take over
-- manual input. The caller must rank actual path collisions ahead of it.
function EscapeSpace.cost(context, endpoint)
    local ex, ey = endpoint.X, endpoint.Y
    local index
    if context.sx > 0 and context.sy > 0 then
        local column = math_floor((ex - context.ox)/context.sx + 0.5)
        local row = math_floor((ey - context.oy)/context.sy + 0.5)
        if column >= 0 and column < context.width and row >= 0 then
            local candidate = column + row * context.width
            index = candidate < context.size and candidate or -1
        else
            index = -1
        end
    else
        index = context.room:GetGridIndex(endpoint)
    end
    local anchor = node(context, index)
    if not anchor then return 999 end
    local pressure = 0
    for i = 1, context.count do
        local enemy = context.enemies[i]
        local d0x, d0y = ex - enemy.x0, ey - enemy.y0
        local d1x, d1y = ex - enemy.x1, ey - enemy.y1
        local clearance = math_min(math_sqrt(d0x*d0x + d0y*d0y), math_sqrt(d1x*d1x + d1y*d1y)) - enemy.radius
        pressure = math_max(pressure, math_max(0, 100 - clearance))
    end
    return math_min(999, math_floor(spaceCost(context, index) + pressure*2))
end

return EscapeSpace
