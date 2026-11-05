-- F5 floor panel: the map of the whole floor on the left (with a legend of
-- the room kinds this floor has), and on the right the floor score, its
-- items (seen or forecast), loot, special rooms, deal/planetarium chances,
-- the Boss Rush/Hush clocks and how far the item forecast can be trusted.
-- All text in the game's language (ui.lua). Display only.
local UI = include("ui")
local M = {}
-- include() gives every caller its own copy of ui.lua; the core hands over
-- the one it uses, so language and fonts are decided in one place.
function M.use(ui) UI = ui end
local floor, max, min = math.floor, math.max, math.min

local PANEL, UNSEEN, SEEN, WHITE, DARK = {0.02, 0.02, 0.04}, {0.32, 0.32, 0.36}, {0.62, 0.62, 0.66}, {1, 1, 1}, {0.05, 0.05, 0.05}
local SIDE = {zh = 200, en = 190}
local function clock(seconds)
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- Loot kinds grouped into a few words; coins count their value.
local GROUPS = {
    {"coins", {coin = 1, nickel = 5, dime = 10}},
    {"keys", {key = 1}}, {"bombs", {bomb = 1}}, {"hearts", {heart = 1, soul = 1}},
    {"chests", {chest = 1, gold = 1}}, {"rocks", {tinted = 1, super = 1, goldrock = 1}},
    {"other", {pill = 1, card = 1, battery = 1, trinket = 1, sack = 1, pickup = 1}},
}
local function lootWords(totals)
    local words = {}
    for _, group in ipairs(GROUPS) do
        local n = 0
        for kind, weight in pairs(group[2]) do n = n + (totals[kind] or 0) * weight end
        n = floor(n + 0.5)
        if n > 0 then words[#words+1] = UI.t(group[1], n) end
    end
    return words
end

-- Words laid out left to right, wrapping at width; returns the next y.
local function flow(words, x, y, width, colour)
    local line, lh, cx = UI.lineHeight(), UI.lineHeight(), x
    for _, word in ipairs(words) do
        local w = UI.width(word)
        if cx > x and cx + w > x + width then cx, y = x, y + lh end
        UI.text(word, cx, y, colour, 1)
        cx = cx + w + UI.width("  ")
    end
    return y + line
end

local function drawMap(floorMap, extras, left, top, width, height)
    local x0, y0, x1, y1 = 99, 99, -1, -1
    for _, room in ipairs(floorMap.rooms) do
        for _, c in ipairs(room.cells) do
            x0, y0, x1, y1 = min(x0, c[1]), min(y0, c[2]), max(x1, c[1]), max(y1, c[2])
        end
    end
    local cols, rows = x1 - x0 + 1, y1 - y0 + 1
    local cw = max(8, min(22, floor(width / cols), floor(height / rows / 0.8)))
    local ch = floor(cw * 0.8)
    left = left + floor((width - cols*cw) / 2)
    for _, room in ipairs(floorMap.rooms) do
        local kind = UI.room(room.type)
        local base = room.visited and SEEN or UNSEEN
        local fill = room.colour or base
        local alpha = room.colour and (room.visited and 0.95 or 0.75) or 0.85
        for _, c in ipairs(room.cells) do
            local x, y = left + (c[1] - x0)*cw, top + (c[2] - y0)*ch
            UI.rect(x + 1, y + 1, cw - 2, ch - 2, fill, alpha)
            if room.colour and not room.visited then UI.frame(x + 1, y + 1, cw - 2, ch - 2, base, 0.9, 1) end
            if room.index == floorMap.current then UI.frame(x, y, cw, ch, WHITE, 1, 2) end
        end
        local first = room.cells[1]
        local x, y = left + (first[1] - x0)*cw, top + (first[2] - y0)*ch
        if kind and cw >= 12 then
            local label = kind[1]
            UI.text(label, x + (cw - UI.width(label))/2, y + (ch - UI.lineHeight())/2, DARK, 1)
        end
        local extra = extras and extras[room.index]
        if extra and (extra.rocks or 0) > 0 then UI.rect(x + cw - 5, y + 2, 3, 3, {1, 0.85, 0.25}, 1) end
        if extra and (extra.items or 0) > 0 then UI.rect(x + 2, y + 2, 3, 3, {0.3, 1, 0.4}, 1)
        elseif extra and (extra.forecast or 0) > 0 then UI.rect(x + 2, y + 2, 3, 3, {0.35, 0.9, 1}, 1) end
    end
    return top + rows*ch
end

-- Legend: one coloured square and name per room kind on this floor.
local function drawLegend(floorMap, x, y, width)
    local seen, words = {}, {}
    for _, room in ipairs(floorMap.rooms) do
        local kind = UI.room(room.type)
        if kind and room.colour and not seen[kind[2]] then
            seen[kind[2]] = true
            words[#words+1] = {kind[2], room.colour}
        end
    end
    local lh, cx = UI.lineHeight(), x
    for _, word in ipairs(words) do
        local w = UI.width(word[1]) + 8
        if cx > x and cx + w > x + width then cx, y = x, y + lh end
        UI.rect(cx, y + lh/2 - 2, 5, 5, word[2], 1)
        UI.text(word[1], cx + 7, y, UI.DIM, 1)
        cx = cx + w + 8
    end
    return y + lh
end

-- Right column; returns nothing. Items fill the room left above the fixed
-- lines below them.
local function drawSide(score, readouts, x, top, width, bottom)
    local lh = UI.lineHeight()
    local y = top
    UI.text(UI.t("score", score.grade, score.total), x, y, score.colour, 1); y = y + lh
    UI.text(UI.t("scoreParts", floor(score.items + 0.5), floor(score.loot + 0.5), floor(score.rooms + 0.5)), x, y, UI.DIM, 1)
    y = y + lh + 3
    -- Fixed lines under the item list.
    local tail = {}
    local loot = lootWords(score.lootTotals)
    local special = {}
    for _, roomType in ipairs(score.special) do
        local kind = UI.room(roomType)
        if kind then special[#special+1] = kind[2] end
    end
    readouts = readouts or {}
    local chances = {}
    if readouts.deal then chances[#chances+1] = UI.t("dealChance", readouts.deal) end
    if readouts.planetarium then chances[#chances+1] = UI.t("planetarium", readouts.planetarium) end
    local clocks = {}
    if readouts.seconds then
        local s = readouts.seconds
        clocks[#clocks+1] = UI.t("time", clock(s))
        for _, gate in ipairs({{"bossRush", 1200}, {"hush", 1800}}) do
            local rest = gate[2] - s
            clocks[#clocks+1] = UI.t(gate[1], rest > 0 and UI.t("left", clock(rest)) or UI.t("closed"))
        end
    end
    local forecast
    if readouts.forecast == "exact" then forecast = UI.t("forecastExact")
    elseif readouts.forecast == "approx" then forecast = UI.t("forecastApprox")
    elseif readouts.forecastWhy == "error" or not readouts.forecastWhy then forecast = UI.t("forecastError")
    else forecast = UI.t("forecastOff", UI.t(readouts.forecastWhy)) end
    -- Lines the tail needs: loot (1-2), rooms, chances, clocks, forecast, mark.
    local tailLines = 7 + (#loot > 4 and 1 or 0)
    UI.text(UI.t("items"), x, y, UI.TEXT, 1); y = y + lh
    local room = max(1, floor((bottom - y) / lh) - tailLines)
    local entries = score.entries
    if #entries == 0 then UI.text("  " .. UI.t("noItems"), x, y, UI.DIM, 1); y = y + lh end
    local shown = #entries <= room and #entries or room - 1
    local nameWidth = width - 40 - UI.width("Q4") - 4
    for i = 1, shown do
        local item = entries[i]
        local kind = UI.room(item.roomType)
        local tag = (item.predicted and "~" or " ") .. (kind and kind[3] or "?")
        local cost = item.devil and (" " .. UI.t("deal")) or (item.price > 0 and (item.predicted and (" " .. UI.t("shop")) or (" $" .. item.price))) or ""
        local colour = UI.QUALITY[item.quality] or UI.TEXT
        UI.text(tag, x, y, item.predicted and {0.35, 0.9, 1} or UI.DIM, 1)
        UI.text(UI.fit(UI.itemName(item.id, item.name) .. cost, nameWidth), x + 40, y, colour, 1)
        UI.text("Q" .. item.quality, x + width - UI.width("Q4"), y, colour, 1)
        y = y + lh
    end
    if shown < #entries then UI.text("  " .. UI.t("more", #entries - shown), x, y, UI.DIM, 1); y = y + lh end
    y = max(y, bottom - tailLines*lh)
    UI.text(UI.t("loot"), x, y, UI.TEXT, 1)
    y = flow(#loot > 0 and loot or {"-"}, x + 40, y, width - 40, UI.DIM)
    UI.text(UI.t("rooms"), x, y, UI.TEXT, 1)
    y = flow(#special > 0 and special or {UI.t("noRooms")}, x + 40, y, width - 40, UI.DIM)
    y = flow(chances, x, y, width, UI.DIM)
    y = flow(clocks, x, y, width, UI.DIM)
    UI.text(forecast, x, y, readouts.forecast == "exact" and UI.GOOD or UI.WARN, 1); y = y + lh
    UI.text(UI.t("forecastMark"), x, y, UI.MUTED, 1)
end

-- floorMap: FloorMap.scan result; extras[listIndex] = {items, forecast,
-- rocks} markers; score: FloorScore result; readouts: FloorIntel readouts.
function M.render(floorMap, extras, score, readouts)
    if not floorMap or #floorMap.rooms == 0 then return end
    local width = Isaac.GetScreenWidth and Isaac.GetScreenWidth() or 480
    local height = Isaac.GetScreenHeight and Isaac.GetScreenHeight() or 270
    local lh = UI.lineHeight()
    local side = score and SIDE[UI.lang()] or 0
    local margin = 14
    local left, top = margin, margin
    local panelW, panelH = width - 2*margin, height - 2*margin
    UI.rect(left - 6, top - 6, panelW + 12, panelH + 12, PANEL, 0.72)
    local mapW = panelW - side - 12
    UI.text(UI.t("mapTitle"), left, top, UI.TEXT, 1)
    UI.text(UI.t("hint"), left + mapW - UI.width(UI.t("hint")), top, UI.MUTED, 1)
    local mapTop = top + lh + 4
    local legendLines = 3
    local mapBottom = drawMap(floorMap, extras, left, mapTop, mapW, panelH - lh - 4 - legendLines*lh - 6)
    drawLegend(floorMap, left, mapBottom + 6, mapW)
    if score then
        local x = left + mapW + 12
        UI.rect(x - 7, top, 1, panelH, UI.MUTED, 0.6)
        drawSide(score, readouts, x, top, side, top + panelH)
    end
end

return M
