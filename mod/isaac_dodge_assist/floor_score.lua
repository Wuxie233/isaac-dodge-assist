-- Floor score: what this floor offers, for deciding whether a run is worth
-- going on with. Items count by their quality (ItemConfig 0-4), loot by
-- pickups and reward rocks, and the rarer rooms by what they usually give.
-- The weights are a rough guide; the lines show what they are made of.
local M = {}
local floor = math.floor

M.ITEM = {[0] = 1, 3, 6, 12, 20}
-- A pedestal not seen yet (a room not entered): about a quality 1-2.
M.UNSEEN_ITEM = 5
-- Shop items cost coins; devil deals cost hearts.
M.SHOP, M.DEVIL = 0.5, 0.6
M.LOOT = {coin = 0.3, nickel = 1.5, dime = 3, key = 1.5, bomb = 1.5, heart = 1, soul = 2,
    chest = 2, gold = 3, sack = 1.5, pill = 1, card = 1, battery = 1.5, trinket = 2, pickup = 0.8,
    tinted = 3, super = 8, goldrock = 1.5, alt = 0.3, skull = 1}
M.ROOM = {ROOM_PLANETARIUM = 8, ROOM_LIBRARY = 5, ROOM_DICE = 4, ROOM_ARCADE = 3, ROOM_SACRIFICE = 3,
    ROOM_CHEST = 5, ROOM_ISAACS = 3, ROOM_BARREN = 2, ROOM_CURSE = 2, ROOM_ULTRASECRET = 6,
    ROOM_CHALLENGE = 3}
local GRADES = {{80, "S", {1, 0.4, 0.95}}, {60, "A", {0.35, 1, 0.45}}, {42, "B", {0.6, 0.9, 1}},
    {28, "C", {0.95, 0.9, 0.5}}, {0, "D", {0.95, 0.5, 0.45}}}

local names
local function typeName(roomType)
    if not names then
        names = {}
        for name, value in pairs(RoomType or {}) do names[value] = name end
    end
    return names[roomType]
end

-- rooms: FloorMap.scan(...).rooms (unvisited ones carry layout =
-- {loot, pedestals, shop}); items[listIndex] = seen items {id, quality,
-- name, price, devil}; loot[listIndex] = loot counted in visited rooms;
-- predicted[listIndex] = forecast items of unvisited rooms, like items
-- plus kind ("pedestal", "shop" or "boss").
-- Returns plain data for the HUD and the map to word in either language:
-- total, grade, colour, items/loot/rooms points, qualities[0-4] counts,
-- unseen (pedestals nothing could name), entries (one per item: id,
-- quality, roomType, predicted, price, devil), lootTotals[kind] and
-- special (room type names worth points, in floor order).
function M.evaluate(rooms, items, loot, predicted)
    local itemPoints, lootPoints, roomPoints = 0, 0, 0
    local qualities, unseen = {[0] = 0, 0, 0, 0, 0}, 0
    local entries, lootTotals, special = {}, {}, {}
    for _, room in ipairs(rooms) do
        local name = typeName(room.type)
        if M.ROOM[name] then
            roomPoints = roomPoints + M.ROOM[name]
            special[#special+1] = room.type
        end
        local list = items[room.index]
        local forecast = not room.visited and predicted and predicted[room.index] or nil
        if not (list and #list > 0) then list = forecast end
        local found = {pedestal = 0, shop = 0, boss = 0}
        for _, item in ipairs(list or {}) do
            local q = item.quality or 1
            local value = M.ITEM[q] or M.UNSEEN_ITEM
            if item.devil then value = value * M.DEVIL elseif (item.price or 0) > 0 then value = value * M.SHOP end
            itemPoints = itemPoints + value
            qualities[q] = (qualities[q] or 0) + 1
            if item.kind then found[item.kind] = found[item.kind] + 1 end
            entries[#entries+1] = {id = item.id, quality = q, name = item.name, roomType = room.type,
                predicted = item.predicted, price = item.price or 0, devil = item.devil}
        end
        if not room.visited and not (items[room.index] and #items[room.index] > 0) then
            -- What the forecast could not name: layout pedestals and shop
            -- slots, and a boss's reward (dropped on the kill, not in the
            -- layout), at the unseen estimate.
            local layout = room.layout or {pedestals = 0, shop = 0}
            local pedestals = math.max(0, layout.pedestals - found.pedestal) +
                ((name == "ROOM_BOSS" and found.boss == 0) and 1 or 0)
            local shop = math.max(0, layout.shop - found.shop)
            itemPoints = itemPoints + pedestals*M.UNSEEN_ITEM + shop*M.UNSEEN_ITEM*M.SHOP
            unseen = unseen + pedestals + shop
        end
        local counts = room.visited and loot[room.index] or room.layout and room.layout.loot
        for kind, count in pairs(counts or {}) do
            lootPoints = lootPoints + (M.LOOT[kind] or 0) * count
            lootTotals[kind] = (lootTotals[kind] or 0) + count
        end
    end
    local total = floor(itemPoints + lootPoints + roomPoints + 0.5)
    local grade, colour
    for _, g in ipairs(GRADES) do
        if total >= g[1] then grade, colour = g[2], g[3] break end
    end
    -- Best items first: quality, then seen before forecast.
    table.sort(entries, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        if (a.predicted or false) ~= (b.predicted or false) then return not a.predicted end
        return a.id < b.id
    end)
    return {total = total, grade = grade, colour = colour, items = itemPoints, loot = lootPoints, rooms = roomPoints,
        qualities = qualities, unseen = floor(unseen + 0.5), entries = entries, lootTotals = lootTotals, special = special}
end

return M
