local TNT = {}

-- Verified against the installed Repentance+ executable: grid tear damage is
-- 1, or 2 when CollisionDamage > 10. TNT's Hurt randomly adds another stage
-- with probability 1/3. Predict the possible increment without consuming RNG.
-- TNTState remains 0..3 damaged / 4 exploded.
local function hasFlag(tear, name)
    local flag = TearFlags[name]
    return flag ~= nil and tear:HasTearFlags(flag)
end
local fallingSamples = setmetatable({}, {__mode="k"})

local function landingThreat(tear, grid, steps, room)
    -- These flags replace ordinary falling, suspend it, or bounce at the
    -- threshold. Their collisions are still handled by explosiveThreat.
    if hasFlag(tear,"TEAR_LUDOVICO") or hasFlag(tear,"TEAR_CHAIN") or
        hasFlag(tear,"TEAR_FETUS") or hasFlag(tear,"TEAR_POP") or
        hasFlag(tear,"TEAR_HYDROBOUNCE") then return false end
    local height, speed, acceleration = tear.Height, tear.FallingSpeed, tear.FallingAcceleration
    if type(height) ~= "number" or type(speed) ~= "number" or type(acceleration) ~= "number" then return false end
    local previous = fallingSamples[tear]
    local scale = previous and previous.scale or 1
    if previous and tear.FrameCount > previous.frame and math.abs(speed)>0.00001 then
        local observed = (height-previous.height)/(speed*(tear.FrameCount-previous.frame))
        if observed > 0 and observed < math.huge then scale = observed end
    end
    if not previous or tear.FrameCount ~= previous.frame then
        fallingSamples[tear] = {height=height,frame=tear.FrameCount,scale=scale}
    end
    local sample = fallingSamples[tear]
    if sample.steps == steps and sample.landings then
        for _, position in ipairs(sample.landings) do
            if position:Distance(grid.Position) < 120 then return true end
        end
        return false
    end
    sample.steps, sample.landings = steps, {}
    -- The native test is Height > -5 BEFORE integrating the next fall tick.
    -- Base integration: v'=0.9^dt*v + dt*(0.1+a), h'=h+dt*v'.
    -- Time scale is not exposed by base Lua; retain the last measured scale
    -- and also the normal-speed case to handle a slow effect ending soon.
    for _, dt in ipairs(scale == 1 and {1} or {scale,1}) do
        local h, v, position = height, speed, tear.Position
        for step=0,steps do
            if h > -5 then
                local clear = tear.GridCollisionClass == EntityGridCollisionClass.GRIDCOLL_NONE or
                    room:CheckLine(tear.Position,position,3,0,false,false)
                if clear then sample.landings[#sample.landings+1] = position end
                break
            end
            if step >= (tear.WaitFrames or 0) then
                v = (0.9^dt)*v + dt*(0.1+acceleration)
                h = h+dt*v
                position = position+tear.Velocity*dt
            end
        end
    end
    for _, position in ipairs(sample.landings) do
        if position:Distance(grid.Position) < 120 then return true end
    end
    return false
end
local function reachesGrid(room, start, finish, grid, mode)
    -- CheckLine returns the first obstruction. Hitting this TNT is expected;
    -- an intervening rock/wall must not count as a future TNT hit.
    local clear, hit = room:CheckLine(start, finish, mode, 0, false, false)
    return clear or (hit and room:GetGridIndex(hit) == room:GetGridIndex(grid.Position))
end

local function tearImpact(tear, grid, steps)
    local delta = tear.Velocity * steps
    local relative = tear.Position - grid.Position
    local radius = 20 + tear.Size
    local a = delta:LengthSquared()
    if relative:LengthSquared() <= radius*radius then return tear.Position end
    if a < 0.0001 then return nil end
    local b = relative:Dot(delta)
    local discriminant = b*b - a*(relative:LengthSquared()-radius*radius)
    if discriminant < 0 then return nil end
    local t = (-b-math.sqrt(discriminant))/a
    if t < 0 or t > 1 then return nil end
    return tear.Position + delta*t
end

local function explosiveThreat(tear, grid, entities, steps, room)
    if not hasFlag(tear,"TEAR_EXPLOSIVE") then return false end
    if landingThreat(tear,grid,steps,room) then return true end
    -- Ipecac's EXPLOSIVE flag explodes on impact. Use the existing conservative
    -- normal-bomb envelope; this is deliberately not an exact explosion radius.
    local blast = 100+20
    if tear.GridCollisionClass ~= EntityGridCollisionClass.GRIDCOLL_NONE then
        local clear, hit = room:CheckLine(tear.Position,tear.Position+tear.Velocity*steps,3,0,false,false)
        if not clear and hit and hit:Distance(grid.Position) < blast then return true end
        local impact = tearImpact(tear,grid,steps)
        if impact and reachesGrid(room,tear.Position,impact,grid,3) then return true end
    end
    -- Explosions on nearby enemies can ignite a barrel even if the tear itself
    -- was not aimed at that barrel. Respect an intervening projectile obstacle.
    for _, entity in ipairs(entities) do
        local npc = entity:ToNPC()
        if npc and npc:IsActiveEnemy(false) and not npc:IsDead() and
            (npc.EntityCollisionClass == EntityCollisionClass.ENTCOLL_PLAYEROBJECTS or
             npc.EntityCollisionClass == EntityCollisionClass.ENTCOLL_ALL) then
            local delta = (tear.Velocity-npc.Velocity)*steps
            local relative = tear.Position-npc.Position
            local a = delta:LengthSquared()
            local c = relative:LengthSquared()-(tear.Size+npc.Size)^2
            local b = relative:Dot(delta)
            local discriminant = b*b-a*c
            local t = c <= 0 and 0 or
                (a > 0 and discriminant >= 0 and (-b-math.sqrt(discriminant))/a or -1)
            if t >= 0 and t <= 1 then
                local impact = tear.Position+tear.Velocity*(steps*t)
                local clear = tear.GridCollisionClass == EntityGridCollisionClass.GRIDCOLL_NONE or
                    room:CheckLine(tear.Position,impact,3,0,false,false)
                if clear and impact:Distance(grid.Position) < blast then return true end
            end
        end
    end
    return false
end

function TNT.threatened(grid, entities, bombs, steps, bombRadius, room)
    local remaining = 4-grid.State
    if remaining <= 0 then return false end
    for _, bomb in ipairs(bombs) do
        if not bomb:IsDead() and bomb.ExplosionDamage > 0 and
            bomb.Position:Distance(grid.Position) < bombRadius(bomb)+20 then
            return true
        end
    end
    local hits = 0
    for _, entity in ipairs(entities) do
        local tear = entity:ToTear()
        if tear and not tear:IsDead() and tear.CollisionDamage > 0 then
            if explosiveThreat(tear,grid,entities,steps,room) then return true end
        end
        if tear and not tear:IsDead() and tear.CollisionDamage > 0 and
            tear.GridCollisionClass ~= EntityGridCollisionClass.GRIDCOLL_NONE then
            local impact = tearImpact(tear,grid,steps)
            if impact and reachesGrid(room,tear.Position,impact,grid,3) then
                -- Acid destroys the grid directly. Rock tears may destroy it
                -- on a damage-scaled random roll; that possible blast needs
                -- warning even when the barrel has not taken damage yet.
                if hasFlag(tear,"TEAR_ACID") or hasFlag(tear,"TEAR_ROCK") then return true end
                if not hasFlag(tear,"TEAR_FETUS_BOMBER") then
                    hits = hits+(tear.CollisionDamage > 10 and 3 or 2)
                end
                if hits >= remaining then return true end
            end
        end
    end
    return false
end

return TNT
