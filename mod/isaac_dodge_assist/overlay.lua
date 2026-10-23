-- Danger preview (F9): draws what the sensor predicts. Display only; it
-- never touches input, so it is safe in Online lobbies.
-- Shapes are captured as plain numbers each sensing update and drawn every
-- render frame with one stretched 4x4 white sprite (lines; circles are
-- polygons). No entity reference survives an update.
local M = {}
local sqrt, atan, cos, sin, pi, max, min = math.sqrt, math.atan, math.cos, math.sin, math.pi, math.max, math.min
local HARD, WARN, PATH = {1, 0.15, 0.15}, {1, 0.75, 0.1}, {1, 0.35, 0.35}
local TARGET, GOAL = {0.3, 0.9, 1}, {0.35, 1, 0.45}
local shapes, marks, enabled, sprite = {}, {}, false, nil

function M.enabled() return enabled end
function M.toggle() enabled = not enabled; if not enabled then shapes, marks = {}, {} end; return enabled end
function M.clear() shapes, marks = {}, {} end

local function line(list, ax, ay, bx, by, color, alpha, width)
    list[#list+1] = {ax, ay, bx, by, color, alpha, width or 1}
end
local function circle(list, x, y, r, color, alpha)
    local n = r < 30 and 10 or (r < 80 and 16 or 24)
    local px, py = x + r, y
    for i = 1, n do
        local a = i * 2 * pi / n
        local nx, ny = x + r*cos(a), y + r*sin(a)
        line(list, px, py, nx, ny, color, alpha, 1)
        px, py = nx, ny
    end
end

-- capture(scene): bullets/contacts carry {x,y,path={x1,y1,x2,y2,...},r};
-- areas/bombs {x,y,r,warning}; lasers are LaserHazards snapshots.
function M.capture(scene, playerRadius)
    if not enabled then return end
    local list = {}
    for _, b in ipairs(scene.bullets) do
        local p = b.path
        for i = 3, #p, 2 do
            line(list, p[i-2], p[i-1], p[i], p[i+1], PATH, max(0.25, 0.9 - i*0.02), 1)
        end
        circle(list, b.x, b.y, b.r + playerRadius, HARD, 0.8)
    end
    for _, e in ipairs(scene.contacts) do circle(list, e.x, e.y, e.r + playerRadius, HARD, 0.7) end
    for _, a in ipairs(scene.areas) do
        circle(list, a.x, a.y, a.r, a.warning and WARN or HARD, a.warning and 0.55 or 0.7)
    end
    for _, shape in ipairs(scene.lasers) do
        local color = shape.warning and WARN or HARD
        local ox, oy = shape.origin.X, shape.origin.Y
        if shape.ring then
            circle(list, ox, oy, shape.radius, color, 0.8)
        else
            local points = shape.points
            for i = 2, #points do
                line(list, ox+points[i-1].X, oy+points[i-1].Y, ox+points[i].X, oy+points[i].Y,
                    color, shape.activeFrom and 0.5 or 0.85, 3)
            end
        end
    end
    shapes = list
end

-- Combat marks (F10 modes): target ring, aim point, standing goal.
function M.combat(info)
    if not enabled then return end
    local list = {}
    if info then
        circle(list, info.targetX, info.targetY, info.targetR + 6, TARGET, 0.9)
        line(list, info.aimX-6, info.aimY, info.aimX+6, info.aimY, TARGET, 0.9, 2)
        line(list, info.aimX, info.aimY-6, info.aimX, info.aimY+6, TARGET, 0.9, 2)
        if info.goalX then
            line(list, info.goalX-8, info.goalY-8, info.goalX+8, info.goalY+8, GOAL, 0.9, 2)
            line(list, info.goalX-8, info.goalY+8, info.goalX+8, info.goalY-8, GOAL, 0.9, 2)
        end
    end
    marks = list
end

local function ensureSprite()
    if sprite then return sprite end
    sprite = Sprite()
    sprite:Load("gfx/iad/iad_shapes.anm2", true)
    sprite:Play("Line", true)
    return sprite
end

-- WorldToScreen ignores the Mirror World flip (noted by Azazel's RangeVis);
-- mirror the screen X there.
local function screen(x, y, mirror, width)
    local p = Isaac.WorldToScreen(Vector(x, y))
    if mirror then p = Vector(width - p.X, p.Y) end
    return p
end
local function draw(s, list, mirror, width)
    for i = 1, #list do
        local item = list[i]
        local a = screen(item[1], item[2], mirror, width)
        local b = screen(item[3], item[4], mirror, width)
        local dx, dy = b.X - a.X, b.Y - a.Y
        local length = sqrt(dx*dx + dy*dy)
        if length > 0.5 then
            local c = item[5]
            s.Color = Color(c[1], c[2], c[3], item[6], 0, 0, 0)
            s.Rotation = atan(dy, dx) * 180 / pi
            s.Scale = Vector(length / 4, item[7] / 4)
            s:Render(a, Vector(0, 0), Vector(0, 0))
        end
    end
end
function M.render(room)
    if not enabled or (#shapes == 0 and #marks == 0) then return end
    local s = ensureSprite()
    local mirror = room and room.IsMirrorWorld and room:IsMirrorWorld() or false
    local width = mirror and Isaac.GetScreenWidth() or 0
    draw(s, shapes, mirror, width)
    draw(s, marks, mirror, width)
end

return M
