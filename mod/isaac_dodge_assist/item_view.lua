-- Item stats and pill effects on screen: the F5 second page (every item of
-- the floor with what picking it up does to the character's stats, and the
-- sum over everything reachable), the tooltip over the pedestal next to
-- the player, and the effect over each pill on the floor. Data:
-- item_stats.lua (stat changes per collectible) and pill_effects.lua (pill
-- effect names and good/bad class). Display only.
local UI = include("ui")
local M = {}
function M.use(ui) UI = ui end

local stats, pills, cards
local function data()
    if stats == nil then
        local ok, t = pcall(include, "item_stats")
        stats = ok and type(t) == "table" and t or false
        ok, t = pcall(include, "pill_effects")
        pills = ok and type(t) == "table" and t or false
        ok, t = pcall(include, "card_effects")
        cards = ok and type(t) == "table" and t or false
    end
    return stats or nil, pills or nil, cards or nil
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
-- of its items). Then the notes (item_notes.lua): each transformation the
-- item counts toward with every player's progress ("Guppy P1 2/3 P2 0/3"),
-- and what the next Spindown Dice uses turn it into.
-- pedestal = {x, y, id, price, next, nextOr, notes}.
local REACH = 70
function M.noteLines(notes)
    local lines = {}
    if not notes then return lines end
    for _, f in ipairs(notes.forms or {}) do
        local words = {{UI.t("form_" .. f.key), UI.TEXT}}
        for _, c in ipairs(f.counts) do
            local done = c[3]
            local text = (#f.counts > 1 and ("P" .. c[1] .. " ") or "") ..
                (done and UI.t("formDone") or (math.min(c[2], 3) .. "/3"))
            -- One more makes it: worth knowing who should take the item.
            local colour = done and UI.MUTED or (c[2] >= 2 and UI.GOOD or UI.DIM)
            words[#words+1] = {text, colour}
        end
        lines[#lines+1] = words
    end
    if notes.spin then
        local words = {{UI.t("spindown"), UI.MUTED}}
        for i, id in ipairs(notes.spin.ids) do
            local quality = id > 0 and UI.quality(id) or nil
            local text = id > 0 and (UI.itemName(id) .. " Q" .. tostring(quality or "?")) or UI.t("spinNone")
            words[#words+1] = {(i > 1 and "> " or "") .. text, UI.QUALITY[quality or 1] or UI.TEXT}
        end
        if notes.spin.carBattery then words[#words+1] = {UI.t("spinBattery"), UI.DIM} end
        lines[#lines+1] = words
    end
    return lines
end
local function wordsWidth(words)
    local w = 0
    for i, word in ipairs(words) do w = w + UI.width(word[1]) + (i > 1 and UI.width(" ")*2 or 0) end
    return w
end
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
    local notes = M.noteLines(best.notes)
    local w = math.max(UI.width(title), after and UI.width(after) or 0, wordsWidth(words))
    for _, n in ipairs(notes) do w = math.max(w, wordsWidth(n)) end
    local lines = 1 + (#words > 0 and 1 or 0) + (after and 1 or 0) + #notes
    local point = Isaac.WorldToScreen(Vector(best.x, best.y))
    local x, y = point.X - w/2, point.Y - 46 - (lines - 1)*lh
    UI.rect(x - 4, y - 2, w + 8, lh*lines + 4, {0, 0, 0}, 0.6)
    UI.text(title, x, y, UI.QUALITY[quality or 1] or UI.TEXT, 1)
    local row = 1
    if #words > 0 then line(words, x, y + lh, x + w + 1, 1); row = 2 end
    if after then UI.text(after, x, y + row*lh, UI.QUALITY[afterQuality or 1] or UI.TEXT, 1); row = row + 1 end
    for _, n in ipairs(notes) do line(n, x, y + row*lh, x + w + 1, 1); row = row + 1 end
end

-- Cards, runes and soul stones on the floor (shop ones too): a tarot card
-- looks like any other until it is used. Each shows its name; the one
-- nearest the player (within reach) also what it does. card = {x, y, id}.
function M.renderCards(list, player)
    local _, _, table_ = data()
    if not table_ or #list == 0 then return end
    local zh = UI.lang() == "zh"
    local near, nearD
    for _, c in ipairs(list) do
        local d = player and math.sqrt((c.x - player.X)^2 + (c.y - player.Y)^2)
        if d and d <= REACH and (not nearD or d < nearD) then near, nearD = c, d end
    end
    local lh = UI.lineHeight()
    for _, c in ipairs(list) do
        local info = table_[c.id]
        if info then
            local colour = info.class == "good" and UI.GOOD or info.class == "bad" and UI.BAD or UI.TEXT
            local name = (zh and info.zh or info.en) or info.en
            local effect = c == near and ((zh and info.effect.zh or info.effect.en) or info.effect.en) or nil
            local w = math.max(UI.width(name), effect and UI.width(effect) or 0)
            local point = Isaac.WorldToScreen(Vector(c.x, c.y))
            local top = point.Y - 30 - (effect and lh or 0)
            UI.rect(point.X - w/2 - 3, top - 1, w + 6, lh*(effect and 2 or 1) + 2, {0, 0, 0}, 0.55)
            UI.text(name, point.X - UI.width(name)/2, top, colour, 1)
            if effect then UI.text(effect, point.X - UI.width(effect)/2, top + lh, UI.TEXT, 1) end
        end
    end
end

-- What an unopened chest or sack, or an alt rock, gives (FloorIntel
-- containers: loot {kind = count}, extras {{key, count, bad}}, items
-- {{id, altOf}}, trinket, bad, empty, rock). Coloured words.
local COIN_VALUE = {coin = 1, nickel = 5, dime = 10}
local LOOT_WORDS = {{"keys", {"key"}}, {"bombs", {"bomb"}}, {"hearts", {"heart"}}, {"souls", {"soul"}},
    {"pills", {"pill"}}, {"cards", {"card"}}, {"trinkets", {"trinket"}}, {"batteries", {"battery"}},
    {"sacks", {"sack"}}, {"chests", {"chest", "gold"}}}
function M.contentWords(c)
    local words = {}
    -- A slot or beggar: which payment pays out first, then what.
    if c.none then return {{UI.t("noPrize"), UI.MUTED}} end
    if c.nth then words[1] = {UI.t("nthPay", c.nth), UI.MUTED} end
    for _, item in ipairs(c.items or {}) do
        local quality = UI.quality(item.id)
        words[#words+1] = {(item.altOf and (UI.t("orWord") .. " ") or "") .. UI.itemName(item.id) ..
            " Q" .. tostring(quality or "?"), UI.QUALITY[quality or 1] or UI.TEXT}
    end
    if c.trinket then words[#words+1] = {UI.trinketName(c.trinket), UI.TEXT} end
    local loot = c.loot or {}
    local coins = 0
    for kind, value in pairs(COIN_VALUE) do coins = coins + (loot[kind] or 0) * value end
    if coins > 0 then words[#words+1] = {UI.t("coins", coins), UI.TEXT} end
    for _, group in ipairs(LOOT_WORDS) do
        local n = 0
        for _, kind in ipairs(group[2]) do n = n + (loot[kind] or 0) end
        if n > 0 then words[#words+1] = {UI.t(group[1], n), UI.TEXT} end
    end
    for _, extra in ipairs(c.extras or {}) do
        words[#words+1] = {UI.t(extra[1], extra[2]), extra[3] and UI.BAD or UI.DIM}
    end
    if c.bad then words[#words+1] = {UI.t("rock_" .. c.bad), UI.BAD} end
    for _, w in ipairs(c.words or {}) do words[#words+1] = {UI.t(w[1]), w[2] and UI.BAD or UI.TEXT} end
    if #words == 0 or (c.nth and #words == 1) then words[#words+1] = {UI.t("emptyChest"), UI.DIM} end
    return words
end
-- Over each one its first words; the one nearest the player all of them.
function M.renderContainers(list, player)
    if #list == 0 then return end
    local near, nearD
    for _, c in ipairs(list) do
        local d = player and math.sqrt((c.x - player.X)^2 + (c.y - player.Y)^2)
        if d and d <= REACH and (not nearD or d < nearD) then near, nearD = c, d end
    end
    local lh, gap = UI.lineHeight(), UI.width("  ")
    for _, c in ipairs(list) do
        local words = M.contentWords(c)
        local point = Isaac.WorldToScreen(Vector(c.x, c.y))
        -- A beggar's prize always shows in full: it is short and the point.
        local full = c == near or c.nth ~= nil
        local maxW = full and 170 or 90
        -- Lay the words out in at most two lines (one for the far ones).
        local lines, line, width = {}, {}, 0
        for _, w in ipairs(words) do
            local ww = UI.width(w[1])
            if #line > 0 and width + gap + ww > maxW then
                lines[#lines+1], line, width = line, {}, 0
            end
            line[#line+1] = w
            width = width + (#line > 1 and gap or 0) + ww
        end
        if #line > 0 then lines[#lines+1] = line end
        local limit = full and 2 or 1
        local cut = #lines > limit
        while #lines > limit do table.remove(lines) end
        if cut then local last = lines[#lines]; last[#last+1] = {"..", UI.DIM} end
        local blockW = 0
        for _, l in ipairs(lines) do
            local w = 0
            for i, word in ipairs(l) do w = w + UI.width(word[1]) + (i > 1 and gap or 0) end
            blockW = math.max(blockW, w)
        end
        local top = point.Y - (c.rock and 22 or 30) - (#lines - 1)*lh
        UI.rect(point.X - blockW/2 - 3, top - 1, blockW + 6, lh*#lines + 2, {0, 0, 0}, 0.55)
        for i, l in ipairs(lines) do
            local x = point.X - blockW/2
            for _, word in ipairs(l) do
                UI.text(word[1], x, top + (i - 1)*lh, word[2], 1)
                x = x + UI.width(word[1]) + gap
            end
        end
    end
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
