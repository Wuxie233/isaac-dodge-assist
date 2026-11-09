-- Floor map (F5): every room of the current floor, including the secret
-- rooms the game's own map has not revealed, from Level:GetRooms(), and
-- what each unvisited room's layout places. Read only: descriptors are
-- never written (DisplayFlags stay untouched), so it is safe in Online
-- lobbies. API notes: native/research/api-map-items.md.
local M = {}

-- Cells on the 13-wide level grid each room shape covers, relative to its
-- SafeGridIndex: the top-left cell, except LTL (top-left missing), whose
-- SafeGridIndex is the top-right cell (MinimapAPI RoomShapePositions).
local W = 13
local SHAPE_CELLS = {
    [1] = {{0,0}},                         -- 1x1
    [2] = {{0,0}},                         -- IH (narrow horizontal)
    [3] = {{0,0}},                         -- IV (narrow vertical)
    [4] = {{0,0},{0,1}},                   -- 1x2
    [5] = {{0,0},{0,1}},                   -- IIV
    [6] = {{0,0},{1,0}},                   -- 2x1
    [7] = {{0,0},{1,0}},                   -- IIH
    [8] = {{0,0},{1,0},{0,1},{1,1}},       -- 2x2
    [9] = {{0,0},{-1,1},{0,1}},            -- LTL
    [10] = {{0,0},{0,1},{1,1}},            -- LTR
    [11] = {{0,0},{1,0},{1,1}},            -- LBL
    [12] = {{0,0},{1,0},{0,1}},            -- LBR
}
function M.cells(safeIndex, shape)
    local x0, y0 = safeIndex % W, safeIndex // W
    local list = {}
    for _, o in ipairs(SHAPE_CELLS[shape] or SHAPE_CELLS[1]) do list[#list+1] = {x0 + o[1], y0 + o[2]} end
    return list
end

-- Room kinds by RoomType name: short label and colour. Kinds missing here
-- are ordinary rooms.
local KINDS = {
    ROOM_SHOP = {"$", {0.35, 0.85, 0.35}},
    ROOM_TREASURE = {"T", {1, 0.85, 0.2}},
    ROOM_BOSS = {"B", {0.95, 0.25, 0.2}},
    ROOM_MINIBOSS = {"M", {0.95, 0.55, 0.2}},
    ROOM_SECRET = {"S", {0.35, 0.6, 1}},
    ROOM_SUPERSECRET = {"SS", {0.25, 0.4, 0.95}},
    ROOM_ULTRASECRET = {"U", {0.95, 0.3, 0.75}},
    ROOM_ARCADE = {"A", {0.3, 0.9, 0.9}},
    ROOM_CURSE = {"C", {0.65, 0.35, 0.85}},
    ROOM_CHALLENGE = {"!", {1, 0.45, 0.3}},
    ROOM_LIBRARY = {"L", {0.75, 0.55, 0.35}},
    ROOM_SACRIFICE = {"X", {0.75, 0.2, 0.25}},
    ROOM_DEVIL = {"D", {0.6, 0.1, 0.1}},
    ROOM_ANGEL = {"An", {0.9, 0.9, 1}},
    ROOM_ISAACS = {"Bd", {0.95, 0.6, 0.75}},
    ROOM_BARREN = {"Bd", {0.7, 0.5, 0.6}},
    ROOM_CHEST = {"V", {0.95, 0.75, 0.3}},
    ROOM_DICE = {"Di", {0.95, 0.95, 0.95}},
    ROOM_BLACK_MARKET = {"BM", {0.5, 0.5, 0.5}},
    ROOM_PLANETARIUM = {"P", {0.3, 0.8, 0.75}},
    ROOM_TELEPORTER = {"Tp", {0.6, 0.8, 1}},
    ROOM_TELEPORTER_EXIT = {"Tp", {0.6, 0.8, 1}},
    ROOM_SECRET_EXIT = {"Ex", {0.8, 0.8, 0.8}},
    ROOM_BOSSRUSH = {"BR", {0.95, 0.25, 0.2}},
    ROOM_ERROR = {"E", {0.8, 0.8, 0.8}},
}
local byType
local function kindOf(roomType)
    if not byType then
        byType = {}
        for name, kind in pairs(KINDS) do
            if RoomType and RoomType[name] then byType[RoomType[name]] = kind end
        end
    end
    return byType[roomType]
end
M.kindOf = kindOf

-- Layout spawn type codes (RoomConfig .stb): grid rocks that drop
-- something, and pickups (EntityType 5) by variant.
local LAYOUT_ROCKS = {[1003] = "tinted", [1011] = "goldrock", [1002] = "alt"}
local RoomFeatures = include("room_features")
local PICKUP = 5
-- What an unvisited room's layout places, as loot counts weighted by how
-- likely each spawn's entry is, plus item pedestals (5.100) and shop
-- slots (5.150). slots lists the spawns that are surely a pedestal or a
-- shop slot (a single entry) with their 0-based spawn index, which seeds
-- the item (ItemForecast). lootKind(variant, subtype) names a pickup kind.
-- Chests and sacks (PickupVariant): their contents follow from the
-- spawn's InitSeed (chest_forecast.lua).
local CONTAINERS = {[50] = true, [51] = true, [52] = true, [53] = true, [54] = true, [55] = true, [56] = true,
    [57] = true, [58] = true, [60] = true, [69] = true, [360] = true, [390] = true}
function M.layout(desc, lootKind)
    local loot, pedestals, shop, slots, containers, features = {}, 0, 0, {}, {}, {}
    local spawns = desc.Data.Spawns
    for i = 0, spawns.Size - 1 do
        local spawn = spawns:Get(i)
        local total = spawn and spawn.SumWeights or 0
        if total > 0 then
            -- PickEntry(r) is a plain lookup by cumulative weight, no RNG.
            local acc = 0
            for _ = 1, spawn.EntryCount do
                local entry = spawn:PickEntry(acc)
                if not entry then break end
                local share = entry.Weight / total
                acc = acc + share
                local kind
                if entry.Type == PICKUP and (entry.Variant == 100 or entry.Variant == 150) and spawn.EntryCount == 1 then
                    slots[#slots+1] = {index = i, variant = entry.Variant, subtype = entry.Subtype}
                end
                if entry.Type == PICKUP and CONTAINERS[entry.Variant] and spawn.EntryCount == 1 then
                    containers[#containers+1] = {index = i, variant = entry.Variant, subtype = entry.Subtype,
                        kind = lootKind(entry.Variant, entry.Subtype)}
                end
                if entry.Type == PICKUP then
                    if entry.Variant == 100 then pedestals = pedestals + share
                    elseif entry.Variant == 150 then shop = shop + share
                    else kind = lootKind(entry.Variant, entry.Subtype) or (entry.Variant == 0 and "pickup") end
                else
                    kind = LAYOUT_ROCKS[entry.Type]
                    local feature = RoomFeatures.fromLayout(entry.Type, entry.Variant, entry.Subtype)
                    if feature then features[feature] = (features[feature] or 0) + share end
                end
                if kind then loot[kind] = (loot[kind] or 0) + share end
            end
        end
    end
    return {loot = loot, pedestals = pedestals, shop = shop, slots = slots, containers = containers, features = features}
end

-- One snapshot of the floor in the current dimension: {rooms={...},
-- current=listIndex}. Each room: index (ListIndex), safe, shape, type,
-- cells, visited, clear, label, colour; layout (unvisited rooms only, via
-- layoutOf(listIndex, desc), which may cache).
function M.scan(level, layoutOf)
    local floor = {rooms = {}, current = nil}
    local list = level:GetRooms()
    local hash = GetPtrHash
    -- Rooms of another dimension (mirror world, mineshaft, Death
    -- Certificate) share grid indexes with this one: keep ours only. Should
    -- the descriptors ever stop comparing equal, keep them all instead of
    -- showing an empty map.
    local ours, any = {}, false
    for i = 0, list.Size - 1 do
        local desc = list:Get(i)
        if desc and desc.Data and desc.SafeGridIndex >= 0 then
            ours[i] = not hash or hash(level:GetRoomByIdx(desc.SafeGridIndex, -1)) == hash(desc)
            any = any or ours[i]
        end
    end
    for i = 0, list.Size - 1 do
        local desc = list:Get(i)
        local data = desc and desc.Data
        if ours[i] ~= nil and (ours[i] or not any) then
            local kind = kindOf(data.Type)
            local visited = (desc.VisitedCount or 0) > 0
            floor.rooms[#floor.rooms+1] = {index = desc.ListIndex, safe = desc.SafeGridIndex, shape = data.Shape,
                type = data.Type, variant = data.Variant, subtype = data.Subtype, flags = desc.Flags,
                spawnSeed = desc.SpawnSeed, awardSeed = desc.AwardSeed,
                cells = M.cells(desc.SafeGridIndex, data.Shape), visited = visited,
                clear = desc.Clear, label = kind and kind[1], colour = kind and kind[2],
                layout = not visited and layoutOf and layoutOf(desc.ListIndex, desc) or nil}
        end
    end
    local current = level:GetCurrentRoomDesc()
    floor.current = current and current.ListIndex
    return floor
end

return M
