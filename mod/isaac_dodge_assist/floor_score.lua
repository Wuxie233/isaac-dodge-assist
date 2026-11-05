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
-- name, price, devil}; loot[listIndex] = loot counted in visited rooms.
function M.evaluate(rooms, items, loot)
    local itemPoints, lootPoints, roomPoints = 0, 0, 0
    local qualities, unseen = {[0] = 0, 0, 0, 0, 0}, 0
    local lines = {}
    for _, room in ipairs(rooms) do
        local name = typeName(room.type)
        roomPoints = roomPoints + (M.ROOM[name] or 0)
        local list = items[room.index]
        if list and #list > 0 then
            for _, item in ipairs(list) do
                local q = item.quality or 1
                local value = M.ITEM[q] or M.UNSEEN_ITEM
                if item.devil then value = value * M.DEVIL elseif (item.price or 0) > 0 then value = value * M.SHOP end
                itemPoints = itemPoints + value
                qualities[q] = (qualities[q] or 0) + 1
                local cost = item.devil and " (deal)" or (item.price or 0) > 0 and (" $" .. item.price) or ""
                lines[#lines+1] = {string.format("%-2s Q%d %s%s", room.label or "-", q,
                    item.name or ("#" .. tostring(item.id)), cost), q >= 3 and {1, 0.85, 0.3} or nil}
            end
        elseif not room.visited then
            local layout = room.layout or {pedestals = 0, shop = 0}
            -- A boss drops its item on the kill: not in the layout.
            local count = layout.pedestals + (name == "ROOM_BOSS" and 1 or 0)
            itemPoints = itemPoints + count*M.UNSEEN_ITEM + layout.shop*M.UNSEEN_ITEM*M.SHOP
            unseen = unseen + count + layout.shop
        end
        local counts = room.visited and loot[room.index] or room.layout and room.layout.loot
        for kind, count in pairs(counts or {}) do
            lootPoints = lootPoints + (M.LOOT[kind] or 0) * count
        end
    end
    local total = floor(itemPoints + lootPoints + roomPoints + 0.5)
    local grade, colour
    for _, g in ipairs(GRADES) do
        if total >= g[1] then grade, colour = g[2], g[3] break end
    end
    local q = {}
    for level = 4, 0, -1 do if qualities[level] > 0 then q[#q+1] = "Q" .. level .. "x" .. qualities[level] end end
    unseen = floor(unseen + 0.5)
    if unseen > 0 then q[#q+1] = "?x" .. unseen end
    local summary = string.format("FLOOR %s %d  items %d (%s)  loot %d  rooms %d", grade, total,
        floor(itemPoints + 0.5), #q > 0 and table.concat(q, " ") or "none", floor(lootPoints + 0.5), floor(roomPoints + 0.5))
    table.insert(lines, 1, {summary, colour})
    return {total = total, grade = grade, colour = colour, summary = summary, lines = lines,
        items = itemPoints, loot = lootPoints, rooms = roomPoints, unseen = unseen}
end

return M
