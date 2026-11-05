-- Screen-space drawing for the floor map (F5) and the floor score line.
-- Shapes are filled rectangles made from the same stretched 4x4 white
-- sprite the danger preview uses; text goes through Isaac.RenderScaledText.
local M = {}
local floor, max, min = math.floor, math.max, math.min
local sprite

local function ensureSprite()
    if sprite then return sprite end
    sprite = Sprite()
    sprite:Load("gfx/iad/iad_shapes.anm2", true)
    sprite:Play("Line", true)
    return sprite
end
-- Filled rectangle (x,y top-left, screen pixels): one horizontal line as
-- thick as the rectangle (the sprite's pivot is its vertical middle).
local function rect(s, x, y, w, h, c, alpha)
    s.Color = Color(c[1], c[2], c[3], alpha, 0, 0, 0)
    s.Rotation = 0
    s.Scale = Vector(w / 4, h / 4)
    s:Render(Vector(x, y + h/2), Vector(0, 0), Vector(0, 0))
end
local function frame(s, x, y, w, h, c, alpha, t)
    rect(s, x, y, w, t, c, alpha); rect(s, x, y + h - t, w, t, c, alpha)
    rect(s, x, y, t, h, c, alpha); rect(s, x + w - t, y, t, h, c, alpha)
end
local function text(str, x, y, scale, c, alpha)
    Isaac.RenderScaledText(str, x, y, scale, scale, c[1], c[2], c[3], alpha or 1)
end
-- Width of RenderText's default font, about 6 pixels a character.
local function textWidth(str, scale) return #str * 6 * scale end

local PANEL = {0, 0, 0}
local UNSEEN, SEEN, WHITE = {0.32, 0.32, 0.36}, {0.62, 0.62, 0.66}, {1, 1, 1}

-- floor: FloorMap.scan result. extras: per room ListIndex {rocks=n,
-- items=n} for small markers. score: FloorScore result (lines shown at the
-- side). Drawn centred on screen.
function M.render(floorMap, extras, score)
    if not floorMap or #floorMap.rooms == 0 then return end
    local s = ensureSprite()
    local x0, y0, x1, y1 = 99, 99, -1, -1
    for _, room in ipairs(floorMap.rooms) do
        for _, c in ipairs(room.cells) do
            x0, y0, x1, y1 = min(x0, c[1]), min(y0, c[2]), max(x1, c[1]), max(y1, c[2])
        end
    end
    local width = Isaac.GetScreenWidth and Isaac.GetScreenWidth() or 480
    local height = Isaac.GetScreenHeight and Isaac.GetScreenHeight() or 270
    local cols, rows = x1 - x0 + 1, y1 - y0 + 1
    local side = score and 150 or 0
    local cw = max(8, min(20, floor((width*0.9 - side) / cols), floor(height*0.75 / rows / 0.8)))
    local ch = floor(cw * 0.8)
    local mapW, mapH = cols*cw, rows*ch
    local left = floor((width - mapW - side) / 2)
    local top = floor((height - mapH) / 2)
    rect(s, left - 6, top - 6, mapW + side + 12, mapH + 24, PANEL, 0.55)
    for _, room in ipairs(floorMap.rooms) do
        local base = room.visited and SEEN or UNSEEN
        local fill = room.colour or base
        local alpha = room.colour and (room.visited and 0.95 or 0.7) or 0.85
        for _, c in ipairs(room.cells) do
            local x, y = left + (c[1] - x0)*cw, top + (c[2] - y0)*ch
            rect(s, x + 1, y + 1, cw - 2, ch - 2, fill, alpha)
            if room.colour and not room.visited then frame(s, x + 1, y + 1, cw - 2, ch - 2, base, 0.9, 1) end
            if room.index == floorMap.current then frame(s, x, y, cw, ch, WHITE, 1, 2) end
        end
        local first = room.cells[1]
        local x, y = left + (first[1] - x0)*cw, top + (first[2] - y0)*ch
        if room.label then
            local scale = cw >= 16 and 0.5 or 0.4
            text(room.label, x + (cw - textWidth(room.label, scale))/2, y + ch/2 - 4*scale - 2, scale, {0.05, 0.05, 0.05}, 1)
        end
        local extra = extras and extras[room.index]
        if extra and (extra.rocks or 0) > 0 then rect(s, x + cw - 5, y + 2, 3, 3, {1, 0.85, 0.25}, 1) end
        if extra and (extra.items or 0) > 0 then rect(s, x + 2, y + 2, 3, 3, {0.3, 1, 0.4}, 1) end
    end
    text("F5 map  T treasure $ shop B boss S/SS/U secret C curse X sacrifice", left, top + mapH + 4, 0.5, {0.85, 0.85, 0.85}, 0.9)
    if score then
        local x, y = left + mapW + 10, top
        for _, line in ipairs(score.lines) do
            text(line[1], x, y, 0.5, line[2] or {0.9, 0.9, 0.9}, 1)
            y = y + 8
        end
    end
end

-- The always-on one-line floor score under the DODGE HUD line.
function M.scoreLine(score, x, y)
    if not score then return end
    text(score.summary, x, y, 0.5, score.colour or {0.9, 0.9, 0.9}, 0.9)
end

return M
