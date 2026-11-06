-- Item stats and pill effects on screen: the F5 second page (every item of
-- the floor with what picking it up does to the character's stats, and the
-- sum over everything reachable), the tooltip over the pedestal next to
-- the player, and the effect over each pill on the floor. Data:
-- item_stats.lua (stat changes per collectible) and pill_effects.lua (pill
-- effect names and good/bad class). Display only.
local UI = include("ui")
local M = {}
function M.use(ui) UI = ui end

local stats, pills
local function data()
    if stats == nil then
        local ok, t = pcall(include, "item_stats")
        stats = ok and type(t) == "table" and t or false
        ok, t = pcall(include, "pill_effects")
        pills = ok and type(t) == "table" and t or false
    end
    return stats or nil, pills or nil
end

-- Stat fields of item_stats.lua in display order: key, string key; mult =
-- a multiplier, min = "at least", neutral = neither good nor bad, bad = more
-- of it is worse (broken hearts).
local FIELDS = {
    {"dmg", "st_dmg"}, {"dmgMult", "st_dmgMult", mult = true}, {"tears", "st_tears"},
    {"fireRate", "st_fireRate"}, {"tearsMult", "st_tearsMult", mult = true},
    {"range", "st_range"}, {"rangeMult", "st_rangeMult", mult = true},
    {"shotSpeed", "st_shotSpeed", neutral = true}, {"shotSpeedMult", "st_shotSpeedMult", mult = true, neutral = true},
    {"speed", "st_speed"}, {"speedMin", "st_speedMin", min = true}, {"luck", "st_luck"},
    {"hearts", "st_hearts"}, {"soul", "st_soul"}, {"black", "st_black"}, {"bone", "st_bone"},
    {"eternal", "st_eternal"}, {"rotten", "st_rotten", neutral = true}, {"broken", "st_broken", bad = true},
}
-- Flags that qualify the numbers rather than add a power: dimmed.
local NOTES = {character = true, oneEye = true, random = true, charged = true}
local function number(v)
    if v == math.floor(v) then return tostring(math.floor(v)) end
    return (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ""))
end
-- Words for one item's stat changes: {text, colour}.
function M.words(entry)
    local out = {}
    if not entry then return out end
    for _, f in ipairs(FIELDS) do
        local v = entry[f[1]]
        if v and v ~= 0 and not (f.mult and v == 1) then
            local text
            if f.mult then text = UI.t(f[2]) .. "x" .. number(v)
            elseif f.min then text = UI.t(f[2]) .. number(v)
            else text = UI.t(f[2]) .. (v > 0 and "+" or "") .. number(v) end
            local good = f.mult and v > 1 or (not f.mult and v > 0)
            if f.bad then good = not good end
            out[#out+1] = {text, f.neutral and UI.DIM or (good and UI.GOOD or UI.BAD)}
        end
    end
    for _, flag in ipairs(entry.flags or {}) do
        local key = "fl_" .. flag
        local text = UI.has(key) and UI.t(key) or nil
        if text then out[#out+1] = {text, NOTES[flag] and UI.DIM or UI.TEXT} end
    end
    if entry.conditional then out[#out+1] = {UI.t("st_conditional"), UI.DIM} end
    return out
end
function M.stats(id)
    local s = data()
    return s and s[id]
end

-- Sum of flat changes and product of multipliers over a list of items.
function M.total(entries)
    local s = data()
    local sum, any = {}, false
    for _, e in ipairs(entries) do
        local st = s and s[e.id]
        if st then
            for _, f in ipairs(FIELDS) do
                local v = st[f[1]]
                if v then
                    any = true
                    if f.mult then sum[f[1]] = (sum[f[1]] or 1) * v
                    elseif f.min then sum[f[1]] = math.max(sum[f[1]] or 0, v)
                    else sum[f[1]] = (sum[f[1]] or 0) + v end
                end
            end
            for _, flag in ipairs(st.flags or {}) do
                sum.flags = sum.flags or {}
                local seen = false
                for _, have in ipairs(sum.flags) do if have == flag then seen = true end end
                if not seen then sum.flags[#sum.flags+1] = flag end
            end
        end
    end
    return any and sum or nil
end

-- Draws words left to right from x, cut at maxX; returns the end x.
local function line(words, x, y, maxX, alpha)
    local gap = UI.width(" ")
    for i, w in ipairs(words) do
        local width = UI.width(w[1])
        if x + width > maxX then
            UI.text("..", x, y, UI.DIM, alpha)
            return x
        end
        UI.text(w[1], x, y, w[2], alpha)
        x = x + width + gap*2
    end
    return x
end
M.line = line
-- Like line, wrapping back to x for up to `lines` lines; returns next y.
local function wrap(words, x, y, maxX, alpha, lines)
    local lh, gap, cx, used = UI.lineHeight(), UI.width(" ")*2, x, 1
    for i, w in ipairs(words) do
        local width = UI.width(w[1])
        if cx > x and cx + width > maxX then
            if used >= lines then UI.text("..", cx, y, UI.DIM, alpha) return y + lh end
            cx, y, used = x, y + lh, used + 1
        end
        UI.text(w[1], cx, y, w[2], alpha)
        cx = cx + width + gap
    end
    return y + lh
end

-- F5 second page: score.entries with their stat words, after the total of
-- what is reachable.
function M.renderPage(score)
    local width = Isaac.GetScreenWidth and Isaac.GetScreenWidth() or 480
    local height = Isaac.GetScreenHeight and Isaac.GetScreenHeight() or 270
    local lh = UI.lineHeight()
    local margin = 14
    local left, top, right = margin, margin, width - margin
    UI.rect(left - 6, top - 6, width - 2*margin + 12, height - 2*margin + 12, {0.02, 0.02, 0.04}, 0.78)
    UI.text(UI.t("pageTitle"), left, top, UI.TEXT, 1)
    UI.text(UI.t("pageHint"), right - UI.width(UI.t("pageHint")), top, UI.MUTED, 1)
    local y = top + lh + 4
    local reachable = {}
    for _, e in ipairs(score.entries) do if (e.factor or 1) > 0 then reachable[#reachable+1] = e end end
    UI.text(UI.t("allTitle"), left, y, UI.TEXT, 1)
    local sum = M.total(reachable)
    local sx = left + UI.width(UI.t("allTitle")) + 8
    if sum then y = wrap(M.words(sum), sx, y, right, 1, 2) + 4
    else UI.text(UI.t("noStats"), sx, y, UI.DIM, 1); y = y + lh + 4 end
    UI.rect(left, y, right - left, 1, UI.MUTED, 0.6)
    y = y + 4
    local rows = math.floor((top + height - 2*margin - y) / lh)
    local nameW = 120
    for i, e in ipairs(score.entries) do
        if i > rows then
            UI.text(UI.t("more", #score.entries - rows + 1), left, y - lh, UI.DIM, 1)
            break
        end
        local alpha = (e.factor or 1) > 0 and 1 or 0.45
        local kind = UI.room(e.roomType)
        UI.text((e.predicted and "~" or " ") .. (kind and kind[3] or "?"), left, y, e.predicted and {0.35, 0.9, 1} or UI.DIM, alpha)
        local colour = UI.QUALITY[e.quality] or UI.TEXT
        local label = (e.altOf and (UI.t("orWord") .. " ") or "") .. UI.itemName(e.id, e.name)
        UI.text(UI.fit(label, nameW), left + 40, y, colour, alpha)
        UI.text("Q" .. e.quality, left + 40 + nameW + 4, y, colour, alpha)
        local x = left + 40 + nameW + 4 + UI.width("Q4") + 8
        local need = e.need and UI.t("need_" .. e.need) or nil
        local maxX = right - (need and (UI.width(need) + 8) or 0)
        local words = M.words(M.stats(e.id))
        if #words == 0 then words = {{UI.t("noStatChange"), UI.MUTED}} end
        line(words, x, y, maxX, alpha)
        if need then UI.text(need, right - UI.width(need), y, UI.WARN, alpha) end
        y = y + lh
    end
end

-- Tooltip over the collectible pedestal nearest the player (within reach):
-- name, quality and stat changes, and in a co-op boss room the item the
-- next pedestal will hold once this one is taken (with Tainted Isaac, both
-- of its items). pedestal = {x, y, id, price, next, nextOr}.
local REACH = 70
function M.renderTooltip(pedestals, player)
    local best, bestD
    for _, p in ipairs(pedestals) do
        local d = math.sqrt((p.x - player.X)^2 + (p.y - player.Y)^2)
        if d <= REACH and (not bestD or d < bestD) then best, bestD = p, d end
    end
    if not best then return end
    local lh = UI.lineHeight()
    local quality = UI.quality(best.id)
    local title = UI.itemName(best.id) .. "  Q" .. tostring(quality or "?")
    local words = M.words(M.stats(best.id))
    local after, afterQuality
    if best.next then
        afterQuality = UI.quality(best.next)
        local named = UI.itemName(best.next)
        if best.nextOr then
            local orQuality = UI.quality(best.nextOr)
            named = named .. " " .. UI.t("orWord") .. " " .. UI.itemName(best.nextOr)
            if orQuality and (not afterQuality or orQuality > afterQuality) then afterQuality = orQuality end
        end
        after = UI.t("nextItem", named) .. "  Q" .. tostring(afterQuality or "?")
    end
    local w = math.max(UI.width(title), after and UI.width(after) or 0)
    local statsW = 0
    for _, word in ipairs(words) do statsW = statsW + UI.width(word[1]) + UI.width(" ")*2 end
    w = math.max(w, statsW)
    local lines = 1 + (#words > 0 and 1 or 0) + (after and 1 or 0)
    local point = Isaac.WorldToScreen(Vector(best.x, best.y))
    local x, y = point.X - w/2, point.Y - 46 - (lines - 1)*lh
    UI.rect(x - 4, y - 2, w + 8, lh*lines + 4, {0, 0, 0}, 0.6)
    UI.text(title, x, y, UI.QUALITY[quality or 1] or UI.TEXT, 1)
    if #words > 0 then line(words, x, y + lh, x + w + 1, 1) end
    if after then UI.text(after, x, y + (lines - 1)*lh, UI.QUALITY[afterQuality or 1] or UI.TEXT, 1) end
end

-- Effect over every pill on the floor. pill = {x, y, effect} (effect id or
-- nil when unknown).
function M.renderPills(list)
    local _, effects = data()
    if not effects then return end
    for _, p in ipairs(list) do
        local info = p.effect and effects[p.effect]
        if info then
            local text = (UI.lang() == "zh" and info.zh or info.en) or info.en
            if p.horse then text = text .. UI.t("horse") end
            local colour = info.class == "good" and UI.GOOD or info.class == "bad" and UI.BAD or UI.TEXT
            local point = Isaac.WorldToScreen(Vector(p.x, p.y))
            local w = UI.width(text)
            UI.rect(point.X - w/2 - 3, point.Y - 30, w + 6, UI.lineHeight() + 2, {0, 0, 0}, 0.55)
            UI.text(text, point.X - w/2, point.Y - 29, colour, 1)
        end
    end
end

return M
