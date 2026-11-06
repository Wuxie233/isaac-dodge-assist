-- UI preview harness: runs the real hud.lua / map_view.lua against a sample
-- floor and prints every draw call (T = text, R = rectangle) for
-- ui_preview.py to rasterize with the game's font atlases.
-- lua5.3 harness.lua <lang> <advances.lua> <scene: hud|panel>
local lang, advancesPath, scene = arg[1], arg[2], arg[3]
local advances = dofile(advancesPath)
local out = {}
function include(name) return dofile('mod/isaac_dodge_assist/' .. name .. '.lua') end
function Vector(x, y) return {X = x, Y = y} end
function Color(r, g, b, a) return {r, g, b, a} end
function KColor(r, g, b, a) return {r, g, b, a} end
RoomType = {ROOM_DEFAULT=1,ROOM_SHOP=2,ROOM_ERROR=3,ROOM_TREASURE=4,ROOM_BOSS=5,ROOM_MINIBOSS=6,ROOM_SECRET=7,ROOM_SUPERSECRET=8,
    ROOM_ARCADE=9,ROOM_CURSE=10,ROOM_CHALLENGE=11,ROOM_LIBRARY=12,ROOM_SACRIFICE=13,ROOM_DEVIL=14,ROOM_ANGEL=15,
    ROOM_ISAACS=18,ROOM_BARREN=19,ROOM_CHEST=20,ROOM_DICE=21,ROOM_BLACK_MARKET=22,ROOM_PLANETARIUM=24,ROOM_ULTRASECRET=29}
Options = {Language = lang}
local function width(str)
    local w = 0
    for _, c in utf8.codes(str) do w = w + (advances[c] or advances[63] or 6) end
    return w
end
function Font()
    local f = {}
    function f:Load(path) self.path = path end
    function f:IsLoaded() return true end
    function f:GetStringWidthUTF8(s) return width(s) end
    function f:DrawStringScaledUTF8(s, x, y, sx, sy, c)
        out[#out+1] = string.format("T\t%s\t%.1f\t%.1f\t%.3f,%.3f,%.3f,%.3f\t%s", self.path, x, y, c[1], c[2], c[3], c[4], s)
    end
    return f
end
function Sprite()
    local s = {}
    function s:Load() end
    function s:Play() end
    function s:Render(pos)
        local w, h = self.Scale.X * 4, self.Scale.Y * 4
        local c = self.Color
        out[#out+1] = string.format("R\t%.1f\t%.1f\t%.1f\t%.1f\t%.3f,%.3f,%.3f,%.3f", pos.X, pos.Y - h/2, w, h, c[1], c[2], c[3], c[4])
    end
    return s
end
Isaac = {GetScreenWidth = function() return 480 end, GetScreenHeight = function() return 270 end,
    GetFrameCount = function() return 0 end, WorldToScreen = function(v) return v end}
local UI = include('ui')
local Hud = include('hud'); Hud.use(UI)
local MapView = include('map_view'); MapView.use(UI)
local ItemView = include('item_view'); ItemView.use(UI)
Isaac.GetItemConfig = function() return {GetCollectible = function(_, id) return {Quality = id == 118 and 4 or 3} end} end
local FloorMap = include('floor_map')
local FloorScore = include('floor_score')

-- A sample floor: start, normal rooms, treasure (seen), boss, secret, super
-- secret, shop (seen items), planetarium, curse, library, sacrifice, an L.
local function room(index, x, y, shape, kind, visited, extra)
    local r = {index = index, safe = y*13 + x, shape = shape, type = kind, visited = visited,
        cells = FloorMap.cells(y*13 + x, shape)}
    local k = FloorMap.kindOf(kind)
    r.label, r.colour = k and k[1], k and k[2]
    for key, value in pairs(extra or {}) do r[key] = value end
    return r
end
local rooms = {
    room(0, 6, 6, 1, 1, true), room(1, 7, 6, 6, 1, true), room(2, 5, 6, 1, 4, true),
    room(3, 6, 5, 4, 1, true), room(4, 9, 6, 1, 2, true), room(5, 6, 4, 1, 1, false),
    room(6, 6, 3, 1, 5, false), room(7, 5, 5, 1, 7, false, {layout = {pedestals = 0, shop = 0, loot = {pill = 3}}}),
    room(8, 8, 5, 1, 8, false, {layout = {pedestals = 1, shop = 0, loot = {}}}),
    room(9, 5, 7, 1, 24, false), room(10, 7, 7, 9, 1, false), room(11, 4, 6, 1, 10, false),
    room(12, 7, 4, 1, 12, false), room(13, 8, 7, 1, 13, false), room(14, 9, 5, 1, 29, false),
}
local items = {[2] = {{id = 118, quality = 4}}, [4] = {{id = 3, quality = 3, price = 15}, {id = 12, quality = 2, price = 15},
    {id = 46, quality = 1, price = 7}}}
-- The boss room's pedestal cycles (Tainted Isaac): its other item, "or".
local predicted = {[6] = {{id = 182, quality = 4, kind = "boss", predicted = true},
        {id = 12, quality = 2, kind = "boss", predicted = true, altOf = 182}},
    [9] = {{id = 588, quality = 3, kind = "pedestal", predicted = true}},
    [12] = {{id = 34, quality = 3, kind = "pedestal", predicted = true}},
    [14] = {{id = 245, quality = 2, kind = "pedestal", predicted = true}}}
local loot = {[0] = {coin = 3, key = 1}, [1] = {bomb = 2, tinted = 1}, [3] = {heart = 2, chest = 1}}
local score = FloorScore.evaluate(rooms, items, loot, predicted)
local readouts = {deal = 34, planetarium = 25, seconds = 7*60 + 41, forecast = "exact"}
local floorMap = {rooms = rooms, current = 0}
local extras = {[2] = {items = 1}, [4] = {items = 3}, [1] = {rocks = 1}}
for index in pairs(predicted) do extras[index] = {forecast = 1} end
if scene == "page" then
    ItemView.renderPage(score)
elseif scene == "room" then
    Hud.render(Hud.new(), {state = "MONITOR / HELPER", combatMode = 2, score = score}, 48, 50)
    ItemView.renderTooltip({{x = 240, y = 150, id = 118, price = 0, next = 182, nextOr = 34}}, Vector(240, 175))
    ItemView.renderPills({{x = 150, y = 200, effect = 1}, {x = 330, y = 200, effect = 8, horse = true}})
elseif scene == "panel" then
    Hud.render(Hud.new(), {state = "MONITOR / HELPER", combatMode = 2, score = score, hidden = true}, 48, 50)
    MapView.render(floorMap, extras, score, readouts)
else
    local hud = Hud.new()
    Hud.toast(hud, UI.t("toastCombat", UI.t("auto")))
    for _ = 1, 30 do out = {}; Hud.render(hud, {state = "THREAT / HELPER", combatMode = 2, player = 2, score = score}, 48, 50) end
    Hud.playerLabel(Vector(240, 170), 2)
end
print(table.concat(out, "\n"))
