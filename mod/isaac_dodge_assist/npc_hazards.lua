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
function M.bombBlast(bomb)
    local at = detonation(bomb)
    if not at then return nil end
    return {position=bomb.Position, velocity=bomb.Velocity,
        radius=BLAST_RADIUS*bomb.RadiusMultiplier, from=math.max(0, at-1), to=at+1}
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

-- Enemies that explode when they die. Boom flies were killed next to the
-- player 8 times across the logs (57-83 units); Mulliboom, Ticking Spider and
-- Poison Mind once or twice each. nil variant = every variant.
local exploders = {
    [EntityType.ENTITY_BOOMFLY] = {[0]=true, [1]=true, [5]=true},
    [EntityType.ENTITY_MULLIGAN] = {[2]=true},
    [EntityType.ENTITY_TICKING_SPIDER] = false,
    [EntityType.ENTITY_POISON_MIND] = false,
    [EntityType.ENTITY_BLACK_BONY] = false,
}
M.BURST_RADIUS = 80
function M.exploder(entity)
    local variants = exploders[entity.Type]
    if variants == nil then return false end
    return variants == false or variants[entity.Variant] == true
end
-- Only an exploder about to die is a warning: one or two player shots away.
function M.deathBurst(npc, player)
    if not M.exploder(npc) then return nil end
    if npc.HitPoints > math.max(3.5, player.Damage*2) then return nil end
    return {position=npc.Position, velocity=npc.Velocity, radius=M.BURST_RADIUS, warning=true}
end
return M
