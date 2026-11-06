-- The always-on HUD: one status line (a coloured dot, dodge state, combat
-- mode, the bound player in co-op), the floor score line, short toasts for
-- key presses, and a player label in co-op only. Strings come from ui.lua
-- in the game's language. Display only.
local UI = include("ui")
local M = {}
-- include() gives every caller its own copy of ui.lua; the core hands over
-- the one it uses, so language and fonts are decided in one place.
function M.use(ui) UI = ui end

local TOAST_FRAMES = 90 -- renders (60 per second)

function M.new() return {toast = nil, toastLeft = 0} end
function M.toast(state, text)
    state.toast, state.toastLeft = text, TOAST_FRAMES
end

-- Sensor state codes (core.lua, also logged as IAD STATE) -> text key and
-- dot colour. Transient ones (room entry, menus) show a dim plain "Dodge".
local STATES = {
    ["MONITOR / HELPER"] = {"dodge", UI.GOOD},
    ["THREAT / HELPER"] = {"dodge", UI.WARN},
    ["PAUSED"] = {"paused", UI.MUTED},
    ["OFF"] = {"dodgeOff", UI.MUTED},
    ["F7: SELECT YOUR PLAYER"] = {"pickPlayer", UI.WARN},
    ["F7: RESELECT PLAYER"] = {"repickPlayer", UI.WARN},
    ["UNSUPPORTED CHARACTER"] = {"unsupported", UI.MUTED},
}
M.STATES = STATES

-- view: {state, combatMode (0 off, 1 aim, 2 auto), preview (F9),
-- player (1-based, nil when alone), score (FloorScore result or nil),
-- hidden (the F5 panel covers the HUD: only toasts)}.
-- (x,y): top-left of the HUD block.
function M.render(state, view, x, y)
    if view.hidden then return M.renderToast(state) end
    local known = STATES[view.state]
    local key, dot = known and known[1] or "standby", known and known[2] or UI.DIM
    local line = UI.lineHeight()
    UI.rect(x, y + line/2 - 2, 4, 4, dot, 0.95)
    local text = UI.t(key)
    if view.combatMode == 1 then text = text .. "   " .. UI.t("aim")
    elseif view.combatMode == 2 then text = text .. "   " .. UI.t("auto") end
    if view.preview then text = text .. "   " .. UI.t("preview") end
    if view.player then text = text .. "   " .. UI.t("you", view.player) end
    UI.text(text, x + 8, y, known and UI.TEXT or UI.DIM, 0.9)
    local score = view.score
    if score then
        local parts = {UI.t("floorLine", score.grade, score.total)}
        for level = 4, 3, -1 do
            local n = score.qualities[level] or 0
            if n > 0 then parts[#parts+1] = "Q" .. level .. "x" .. n end
        end
        if score.unseen > 0 then parts[#parts+1] = UI.t("unseenItems", score.unseen) end
        UI.text(table.concat(parts, "  "), x + 8, y + line, score.colour, 0.85)
    end
    M.renderToast(state)
end
function M.renderToast(state)
    local line = UI.lineHeight()
    if state.toastLeft > 0 then
        state.toastLeft = state.toastLeft - 1
        local width = Isaac.GetScreenWidth and Isaac.GetScreenWidth() or 480
        local w = UI.width(state.toast)
        local alpha = math.min(1, state.toastLeft / 20)
        UI.rect((width - w)/2 - 6, 26, w + 12, line + 4, {0, 0, 0}, 0.55*alpha)
        UI.text(state.toast, (width - w)/2, 28, UI.TEXT, alpha)
    end
end

-- In co-op, which character the assist is driving.
function M.playerLabel(position, player)
    local point = Isaac.WorldToScreen(position)
    local label = UI.t("you", player)
    UI.text(label, point.X - UI.width(label)/2, point.Y - 48, UI.GOOD, 0.8)
end

return M
