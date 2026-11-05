-- Floor score: what this floor offers, for deciding whether a run is worth
-- going on with. Items count by their quality (ItemConfig 0-4), loot by
-- pickups and reward rocks, and the rarer rooms by what they usually give.
-- The weights are a rough guide; the lines show what they are made of.
local M = {}
local floor = math.floor

M.ITEM = {[0] = 1, 3, 6, 12, 20}
-- A pedestal not seen yet (a room not entered): about a quality 1-2.
M.UNSEEN_ITEM = 5
-- Shop items cost coins (more when we cannot pay yet); devil deals cost
-- hearts.
M.SHOP, M.SHOP_SHORT, M.DEVIL = 0.7, 0.3, 0.6
-- What it takes to get into a room not entered yet (from floor 2 on the
-- item rooms are locked), and what is left of its worth without it: a key
-- or a bomb can still turn up, a red-door tool that is not even unlocked
-- cannot.
M.NEEDS = {ROOM_SECRET = "bomb", ROOM_SUPERSECRET = "bomb", ROOM_ULTRASECRET = "red"}
M.LOCKED = {ROOM_TREASURE = true, ROOM_SHOP = true, ROOM_PLANETARIUM = true, ROOM_LIBRARY = true,
    ROOM_CHEST = true, ROOM_DICE = true}
M.WITHOUT = {key = 0.4, bomb = 0.4, red = 0.25, redLocked = 0}
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

-- What an unvisited room needs and how much of it counts, given access =
-- {keys, bombs, coins, stage, redHeld, redUnlocked} (nil: all counts).
-- Returns need ("key", "bomb", "red", "redLocked" or nil) and a factor.
function M.access(roomName, visited, access)
    if visited or not access then return nil, 1 end
    local need = M.NEEDS[roomName]
    if not need and M.LOCKED[roomName] and (access.stage or 1) >= 2 then need = "key" end
    if need == "key" and access.keys > 0 then return nil, 1 end
    if need == "bomb" and access.bombs > 0 then return nil, 1 end
    if need == "red" then
        if access.redHeld then return nil, 1 end
        if not access.redUnlocked then need = "redLocked" end
    end
    if not need then return nil, 1 end
    return need, M.WITHOUT[need]
end

-- rooms: FloorMap.scan(...).rooms (unvisited ones carry layout =
-- {loot, pedestals, shop}); items[listIndex] = seen items {id, quality,
-- name, price, devil}; loot[listIndex] = loot counted in visited rooms;
-- predicted[listIndex] = forecast items of unvisited rooms, like items
-- plus kind ("pedestal", "shop" or "boss").
-- Returns plain data for the HUD and the map to word in either language:
-- total, grade, colour, items/loot/rooms points, qualities[0-4] counts,
-- unseen (pedestals nothing could name), entries (one per item: id,
-- quality, roomType, predicted, price, devil, need, factor), lootTotals[kind]
-- and special (room type names worth points, in floor order). access (see
-- M.access) discounts what we cannot get into or pay for yet.
function M.evaluate(rooms, items, loot, predicted, access)
    -- A boss drops one item per person.
    local bossItems = math.max(1, access and access.players or 1)
    local itemPoints, lootPoints, roomPoints = 0, 0, 0
    local qualities, unseen = {[0] = 0, 0, 0, 0, 0}, 0
    local entries, lootTotals, special = {}, {}, {}
    for _, room in ipairs(rooms) do
        local name = typeName(room.type)
        local need, reach = M.access(name, room.visited, access)
        if M.ROOM[name] then
            roomPoints = roomPoints + M.ROOM[name]*reach
            special[#special+1] = room.type
        end
        local list = items[room.index]
        local forecast = not room.visited and predicted and predicted[room.index] or nil
        if not (list and #list > 0) then list = forecast end
        local found = {pedestal = 0, shop = 0, boss = 0}
        for _, item in ipairs(list or {}) do
            local q = item.quality or 1
            local value = M.ITEM[q] or M.UNSEEN_ITEM
            local factor, itemNeed = reach, need
            if item.devil then factor = factor * M.DEVIL
            elseif (item.price or 0) > 0 then
                -- A forecast shop slot has no price yet (price 1 marks it).
                local short = access and not item.predicted and access.coins < item.price
                factor = factor * (short and M.SHOP_SHORT or M.SHOP)
                if short and not itemNeed then itemNeed = "coins" end
            end
            itemPoints = itemPoints + value*factor
            qualities[q] = (qualities[q] or 0) + 1
            if item.kind then found[item.kind] = found[item.kind] + 1 end
            entries[#entries+1] = {id = item.id, quality = q, name = item.name, roomType = room.type,
                predicted = item.predicted, price = item.price or 0, devil = item.devil, need = itemNeed, factor = factor}
        end
        if not room.visited and not (items[room.index] and #items[room.index] > 0) then
            -- What the forecast could not name: layout pedestals and shop
            -- slots, and a boss's reward (dropped on the kill, not in the
            -- layout), at the unseen estimate.
            local layout = room.layout or {pedestals = 0, shop = 0}
            local pedestals = math.max(0, layout.pedestals - found.pedestal) +
                (name == "ROOM_BOSS" and math.max(0, bossItems - found.boss) or 0)
            local shop = math.max(0, layout.shop - found.shop)
            itemPoints = itemPoints + (pedestals*M.UNSEEN_ITEM + shop*M.UNSEEN_ITEM*M.SHOP)*reach
            unseen = unseen + pedestals + shop
        end
        local counts = room.visited and loot[room.index] or room.layout and room.layout.loot
        for kind, count in pairs(counts or {}) do
            lootPoints = lootPoints + (M.LOOT[kind] or 0) * count * reach
            lootTotals[kind] = (lootTotals[kind] or 0) + count
        end
    end
    local total = floor(itemPoints + lootPoints + roomPoints + 0.5)
    local grade, colour
    for _, g in ipairs(GRADES) do
        if total >= g[1] then grade, colour = g[2], g[3] break end
    end
    -- Reachable items first, best first; then seen before forecast.
    table.sort(entries, function(a, b)
        if (a.factor > 0) ~= (b.factor > 0) then return a.factor > 0 end
        if a.quality ~= b.quality then return a.quality > b.quality end
        if (a.predicted or false) ~= (b.predicted or false) then return not a.predicted end
        return a.id < b.id
    end)
    return {total = total, grade = grade, colour = colour, items = itemPoints, loot = lootPoints, rooms = roomPoints,
        qualities = qualities, unseen = floor(unseen + 0.5), entries = entries, lootTotals = lootTotals, special = special}
end

return M
