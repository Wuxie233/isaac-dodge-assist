local EscapeSpace = {}
local NEIGHBORS = {{-1,0},{1,0},{0,-1},{0,1}}
local DEPTH = 4

-- One context per decision update. Geometry, enemy forecasts and local flood
-- results are shared by every straight/turning candidate in that update.
function EscapeSpace.build(room, player, contacts, steps, forecast, gridSafe)
    local context = {room=room, player=player, safe=gridSafe,
        width=room:GetGridWidth(), size=room:GetGridSize(),
        nodes={}, costs={}, enemies={}}
    for _, enemy in ipairs(contacts) do
        local radius = player.Size + enemy.Size + 7
        context.enemies[#context.enemies+1] = {
            position=forecast(enemy,steps), later=forecast(enemy,steps+4), radius=radius}
    end
    return context
end

local function node(context, index)
    if index < 0 or index >= context.size then return nil end
    local cached = context.nodes[index]
    if cached ~= nil then return cached or nil end
    local position = context.room:GetGridPosition(index)
    if not context.safe(context.room,context.player,position) then
        context.nodes[index] = false
        return nil
    end
    local clearance = 100
    for _, enemy in ipairs(context.enemies) do
        local distance = math.min((position-enemy.position):Length(),
            (position-enemy.later):Length()) - enemy.radius
        clearance = math.min(clearance,distance)
    end
    if clearance <= 0 then
        context.nodes[index] = false
        return nil
    end
    cached = {position=position, clearance=clearance, edges={}}
    context.nodes[index] = cached
    return cached
end

local function edgeDistance(point, a, b)
    local dx,dy = b.X-a.X,b.Y-a.Y
    local length = dx*dx+dy*dy
    local t = length == 0 and 0 or math.max(0,math.min(1,((point.X-a.X)*dx+(point.Y-a.Y)*dy)/length))
    local x,y = point.X-a.X-dx*t,point.Y-a.Y-dy*t
    return math.sqrt(x*x+y*y)
end

local function neighbor(context, index, direction)
    local x = index % context.width + direction[1]
    if x < 0 or x >= context.width then return nil end
    local nextIndex = index + direction[1] + direction[2]*context.width
    local current, nextNode = node(context,index), node(context,nextIndex)
    if not current or not nextNode then return nil end
    local connected = current.edges[nextIndex]
    if connected == nil then
        connected = context.safe(context.room,context.player,
            (current.position+nextNode.position)*0.5)
        if connected then
            for _,enemy in ipairs(context.enemies) do
                if math.min(edgeDistance(enemy.position,current.position,nextNode.position),
                    edgeDistance(enemy.later,current.position,nextNode.position)) <= enemy.radius then
                    connected = false
                    break
                end
            end
        end
        current.edges[nextIndex] = connected
        nextNode.edges[index] = connected
    end
    if connected then return nextIndex end
end

local function spaceCost(context, index)
    if context.costs[index] then return context.costs[index] end
    local queue, depths, seen = {index}, {0}, {[index]=true}
    local head, exits, reach = 1, 0, 0
    while head <= #queue do
        local current, depth = queue[head], depths[head]
        head = head+1
        -- A bounded four-connected flood: at most 41 nodes per endpoint.
        -- A narrow entrance cannot borrow open cells across a wall or enemy.
        reach = reach+1
        if depth < DEPTH then
            for _, direction in ipairs(NEIGHBORS) do
                local nextIndex = neighbor(context,current,direction)
                if nextIndex then
                    if depth == 0 then exits = exits+1 end
                    if not seen[nextIndex] then
                        seen[nextIndex] = true
                        queue[#queue+1], depths[#depths+1] = nextIndex,depth+1
                    end
                end
            end
        end
    end
    local result = (41-reach)*12 + (4-exits)*70
    context.costs[index] = result
    return result
end

-- This is a tie-break cost, never a damage score or a reason to take over
-- manual input. The caller must rank actual path collisions ahead of it.
function EscapeSpace.cost(context, endpoint)
    local index = context.room:GetGridIndex(endpoint)
    local anchor = node(context,index)
    if not anchor then return 999 end
    local pressure = 0
    for _, enemy in ipairs(context.enemies) do
        local clearance = math.min((endpoint-enemy.position):Length(),
            (endpoint-enemy.later):Length()) - enemy.radius
        pressure = math.max(pressure,math.max(0,100-clearance))
    end
    return math.min(999,math.floor(spaceCost(context,index)+pressure*2))
end

return EscapeSpace
