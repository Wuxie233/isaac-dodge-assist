-- Which effect a pill on the floor has, before anyone takes it:
-- ItemPool:GetPillEffect(color, player), the same call the game makes when
-- the pill is swallowed (PHD, False PHD, Lucky Foot, Virgo and the
-- low-health swaps included). Decompiled and found to be a pure read
-- (native/research/stats-and-pills.md §2.3); its one outside effect is
-- firing MC_GET_PILL_EFFECT, so while any mod hooks that event (this one
-- never does) pills stay unknown.
local M = {}
local GIANT = 0x800 -- PillColor.PILL_GIANT_FLAG: a horse pill

local function hooked()
    if not (Isaac.GetCallbacks and ModCallbacks.MC_GET_PILL_EFFECT) then return true end
    local ok, list = pcall(Isaac.GetCallbacks, ModCallbacks.MC_GET_PILL_EFFECT)
    return not ok or (list ~= nil and #list > 0)
end

-- color: the pill pickup's SubType. Returns effect id (or nil) and whether
-- it is a horse pill.
function M.effect(game, color, player)
    local horse = color & GIANT ~= 0
    if not player or hooked() then return nil, horse end
    local effect = game:GetItemPool():GetPillEffect(color, player)
    return effect and effect >= 0 and effect or nil, horse
end
return M
