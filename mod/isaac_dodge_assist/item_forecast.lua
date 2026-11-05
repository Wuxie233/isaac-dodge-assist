-- Item forecast: which items the pedestals of rooms not entered yet will
-- hold, from item_emulator.lua, a pure-Lua copy of the game's item pools
-- kept in step with every pick the game makes (124 of 126 logged picks;
-- native/research/item-emulation.md). ItemPool is never called: the only
-- inputs are reads (seeds, unlock state through IsAvailable, owned items)
-- and the picks the game reports through MC_POST_GET_COLLECTIBLE.
local Emu = include("item_emulator")
local M = {}
local data

local CHAOS, TMTRAINER = 402, 721
local FLAG_DEVIL_TREASURE = 1 << 11
local DEVIL, BLACK_MARKET = 14, 22

-- A fresh copy of the pools for the current run. exact=false when picks
-- before now were missed (continued run, mod loaded mid-run).
function M.start(game, exact)
    data = data or include("item_pool_data")
    local seed = game:GetSeeds():GetStartSeed()
    -- version counts changes to the pools: forecasts are redone only then.
    local state = {emu = Emu.new(data, seed), seed = seed, exact = exact, available = {}, version = 0}
    M.removeOwned(state, game)
    return state
end
-- After a reload the copy keeps its tables; methods come from this module.
function M.adopt(state)
    if state and state.emu then setmetatable(state.emu, Emu.Emu) end
    return state
end

-- The game picked `item` from `pool`; with decrease it also took it out.
function M.picked(state, item, pool, decrease)
    if state and decrease and item and item > 0 then
        state.emu:recordPick(pool, item)
        state.version = state.version + 1
    end
end
-- An item on a pedestal or owned by a player is out of every pool.
function M.seen(state, item)
    if state and item and item > 0 and not state.emu:isRemoved(item) then
        state.emu:removeCollectible(item)
        state.version = state.version + 1
    end
end
function M.removeOwned(state, game)
    for i = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(i)
        for id in pairs(data.items) do
            if player:GetCollectibleNum(id) > 0 then M.seen(state, id) end
        end
    end
end
function M.newRoom(state, game)
    if not state then return end
    state.emu:newRoom()
    state.available = {}
    state.version = state.version + 1
    M.removeOwned(state, game)
end

-- Why no forecast can be trusted now, or nil.
function M.blocked(game)
    if game:IsGreedMode() then return "greed" end
    if Isaac.GetChallenge and Isaac.GetChallenge() ~= 0 then return "challenge" end
    for i = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(i)
        if player:HasCollectible(CHAOS) then return "chaos" end
        if player:HasCollectible(TMTRAINER) then return "tmtrainer" end
    end
    return nil
end

local function options(state, game)
    local config = Isaac.GetItemConfig()
    local cache = state.available
    -- NO! (trinket 88) bans active items from every pick.
    local no, banActives = TrinketType and TrinketType.TRINKET_NO or 88, false
    for i = 0, game:GetNumPlayers() - 1 do
        if Isaac.GetPlayer(i):HasTrinket(no) then banActives = true end
    end
    return {banActives = banActives, isAvailable = function(id)
        local known = cache[id]
        if known == nil then
            local item = config:GetCollectible(id)
            known = item ~= nil and item:IsAvailable()
            cache[id] = known
        end
        return known
    end}
end

-- Forecast for one unvisited room (FloorMap room with spawnSeed, awardSeed,
-- flags, subtype, type and layout.slots): a list of {id, kind} with kind
-- "pedestal", "shop" or "boss". Shop slots only in devil rooms and black
-- markets (an ordinary shop mixes slot types the copy does not model).
function M.room(state, game, room)
    local slots = room.layout and room.layout.slots or {}
    local pool = Emu.poolForRoom(room.type, {subtype = room.subtype,
        devilTreasure = (room.flags or 0) & FLAG_DEVIL_TREASURE ~= 0})
    if not pool then return nil end
    local opts = options(state, game)
    local picks, kinds, out = {}, {}, {}
    for _, slot in ipairs(slots) do
        if slot.variant == 100 and slot.subtype > 0 then
            out[#out+1] = {id = slot.subtype, kind = "pedestal"}
        elseif slot.variant == 100 or ((room.type == DEVIL or room.type == BLACK_MARKET) and slot.variant == 150) then
            picks[#picks+1] = {pool, Emu.layoutPickSeed(room.spawnSeed, slot.index)}
            kinds[#picks] = slot.variant == 150 and "shop" or "pedestal"
        end
    end
    if #picks > 0 then
        local items = state.emu:predictRoom(picks, opts)
        for i = 1, #picks do
            if items[i] then out[#out+1] = {id = items[i], kind = kinds[i]} end
        end
    end
    if room.type == 5 then
        -- A boss drops its reward on the kill (the Horsemen a fixed item).
        local rewardPool = Emu.bossRewardPool(room.subtype)
        local id = rewardPool and state.emu:predict(rewardPool, Emu.bossPickSeed(room.awardSeed), opts)
        if id then out[#out+1] = {id = id, kind = "boss"} end
    end
    return out
end

function M.quality(id)
    local item = data and data.items[id]
    return item and item.q
end

return M
