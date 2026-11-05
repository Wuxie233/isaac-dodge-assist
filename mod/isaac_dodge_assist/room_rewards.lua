-- Rocks that drop something when broken, in the current room: tinted rocks
-- (the marked ones), super tinted, fool's gold, and the stage's alternate
-- rocks (urns, mushrooms, skulls, polyps). Listed while still unbroken, for
-- the overlay to mark. Read only.
local M = {}

-- kind -> {label, colour}; built from GridEntityType names that exist.
local KINDS = {
    GRID_ROCKT = {"tinted", {1, 0.85, 0.25}},
    GRID_ROCK_SS = {"super", {1, 0.4, 0.95}},
    GRID_ROCK_GOLD = {"gold", {1, 0.95, 0.4}},
    GRID_ROCK_ALT = {"alt", {0.75, 0.75, 0.8}},
    GRID_ROCK_ALT2 = {"skull", {0.9, 0.9, 0.9}}, -- marked skull: the Fool card after Mother
}
local byType
local function kinds()
    if not byType then
        byType = {}
        for name, kind in pairs(KINDS) do
            if GridEntityType and GridEntityType[name] then byType[GridEntityType[name]] = kind end
        end
    end
    return byType
end
M.LABELS = KINDS

-- Rescanned on entering a room and then every RESCAN updates: a rock only
-- ever breaks, so a stale list errs by marking one rock too long.
local RESCAN = 15
-- {x, y, label, colour} per unbroken reward rock.
function M.scan(room)
    local list, known = {}, kinds()
    for index = 0, room:GetGridSize() - 1 do
        local grid = room:GetGridEntity(index)
        local kind = grid and known[grid:GetType()]
        -- State 2 is a destroyed rock; its cell also stops colliding.
        if kind and grid.State ~= 2 and room:GetGridCollision(index) ~= GridCollisionClass.COLLISION_NONE then
            list[#list+1] = {x = grid.Position.X, y = grid.Position.Y, label = kind[1], colour = kind[2], index = index}
        end
    end
    return list
end

function M.new() return {room = nil, at = -RESCAN, list = {}} end
-- Current list for this update (frame counts from the room's entry).
function M.update(state, room, frame)
    if state.room ~= room or frame - state.at >= RESCAN or frame < state.at then
        state.room, state.at, state.list = room, frame, M.scan(room)
    end
    return state.list
end

return M
