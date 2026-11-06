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
-- After a reload the copy keeps its tables; methods and the pool data come
-- from this module (a reloaded core never ran M.start).
function M.adopt(state)
    data = data or include("item_pool_data")
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
-- Collectibles the game has a config for. GetCollectibleNum on an id
-- without one reads through a null config in some player states and takes
-- the game down (2026-11-05, entering the Deathmatch room, id 43): never
-- ask about one.
local ownable
local function ownableIds()
    if not ownable then
        local config, list = Isaac.GetItemConfig(), {}
        for id in pairs(data.items) do
            if config:GetCollectible(id) then list[#list+1] = id end
        end
        ownable = list
    end
    return ownable
end
function M.removeOwned(state, game)
    local ids = ownableIds()
    for i = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(i)
        for _, id in ipairs(ids) do
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

-- How many people play: one per controller (Esau and other second bodies
-- share their player's). A boss room drops one item per person.
function M.players(game)
    local seen, n = {}, 0
    for i = 0, game:GetNumPlayers() - 1 do
        local controller = Isaac.GetPlayer(i).ControllerIndex or i
        if not seen[controller] then seen[controller], n = true, n + 1 end
    end
    return n
end

local VOID = 12
local function stageOf(game)
    local ok, stage = pcall(function() return game:GetLevel():GetStage() end)
    return ok and stage or 0
end
-- The boss that ends a chapter drops no item. 2026-11-04..06 logs: It Lives
-- x6, Mom's Heart, Hush x3, Isaac, Satan, The Lamb x2, Mega Satan x2 and
-- Delirium x2 killed, none with an item; in The Void the bosses do drop one
-- (Satan included), Delirium does not. Boss ids as the game records them:
-- Mom's Heart 8, Satan 24, It Lives 25, Isaac 39, ??? 40, The Lamb 54, Mega
-- Satan 55, Hush 63, Delirium 70, Mother 88 (??? and Mother not logged yet).
local NO_REWARD = {[8] = true, [24] = true, [25] = true, [39] = true, [40] = true, [54] = true,
    [55] = true, [63] = true, [70] = true, [88] = true}
local DELIRIUM = 70
-- How many items a boss room drops: one per person, or none.
function M.bossItems(game, room)
    if room.type ~= 5 then return 0 end
    if NO_REWARD[room.subtype] and (stageOf(game) ~= VOID or room.subtype == DELIRIUM) then return 0 end
    return M.players(game)
end

-- Tainted Isaac in the party: every pedestal cycles between two items.
local ISAAC_B = 21
function M.cycles(game)
    for i = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(i)
        if player.GetPlayerType and player:GetPlayerType() == ISAAC_B then return true end
    end
    return false
end

-- Forecast for one unvisited room (FloorMap room with spawnSeed, awardSeed,
-- flags, subtype, type and layout.slots): a list of {id, kind, altOf} with
-- kind "pedestal", "shop" or "boss". Shop slots only in devil rooms and
-- black markets (an ordinary shop mixes slot types the copy does not model).
-- A boss room's reward follows its layout; with two or more people the
-- second person's boss-pool item follows it (later ones are not modelled).
-- In The Void the first reward comes from a pool picked at random, which is
-- not modelled. With Tainted Isaac every pedestal's second item (altOf =
-- the first one's id) follows it.
function M.room(state, game, room)
    local slots = room.layout and room.layout.slots or {}
    local pool = Emu.poolForRoom(room.type, {subtype = room.subtype,
        devilTreasure = (room.flags or 0) & FLAG_DEVIL_TREASURE ~= 0})
    if not pool then return nil end
    local opts = options(state, game)
    local cycles = M.cycles(game)
    local picks, kinds, seconds, out = {}, {}, {}, {}
    local function add(pick, kind, second) picks[#picks+1] = pick; kinds[#picks] = kind; seconds[#picks] = second end
    -- One pedestal: its pick (nil when not modelled), then Tainted Isaac's
    -- second item from the same pool (the boss pool in The Void).
    local function pedestal(poolType, pickSeed, initSeed, kind, secondPool)
        if pickSeed then add({poolType, pickSeed}, kind) end
        if cycles then add({secondPool or poolType, Emu.altPickSeed(initSeed)}, kind, pickSeed ~= nil) end
    end
    for _, slot in ipairs(slots) do
        if slot.variant == 100 and slot.subtype > 0 then
            out[#out+1] = {id = slot.subtype, kind = "pedestal"}
        elseif slot.variant == 100 or ((room.type == DEVIL or room.type == BLACK_MARKET) and slot.variant == 150) then
            local init = Emu.layoutInitSeed(room.spawnSeed, slot.index)
            pedestal(pool, Emu.pickSeedFromInitSeed(init), init, slot.variant == 150 and "shop" or "pedestal")
        end
    end
    -- A boss drops its reward on the kill (the Horsemen a fixed item).
    local rewards = M.bossItems(game, room)
    local rewardPool = rewards > 0 and Emu.bossRewardPool(room.subtype)
    if rewardPool then
        local first = Emu.bossItemInitSeed(room.awardSeed, room.subtype)
        local void = stageOf(game) == VOID
        pedestal(rewardPool, not void and Emu.bossPickSeed(room.awardSeed) or nil, first, "boss",
            void and Emu.POOL.BOSS or nil)
        if rewards > 1 then
            pedestal(Emu.POOL.BOSS, Emu.extraBossPickSeed(first), Emu.extraBossInitSeed(first), "boss")
        end
    end
    if #picks > 0 then
        local items = state.emu:predictRoom(picks, opts)
        for i = 1, #picks do
            if items[i] then
                local altOf = seconds[i] and items[i-1] or nil
                if altOf ~= items[i] then out[#out+1] = {id = items[i], kind = kinds[i], altOf = altOf} end
            end
        end
    end
    return out
end

-- In a cleared boss room with two or more people: the first reward
-- pedestal (found by its InitSeed) and the item the next pedestal will hold
-- once it is taken. pedestals = {seed (InitSeed), ...}; nil when there is
-- none to tell.
-- With Tainted Isaac also the next pedestal's second item.
function M.bossNext(state, game, room, pedestals)
    if not state or room.type ~= 5 or M.bossItems(game, room) < 2 then return nil end
    local s, first = room.awardSeed & 0xFFFFFFFF, {}
    for n = 1, 3 do
        s = Emu.next(s, 35)
        if n >= 2 then first[s] = true end
    end
    for _, pedestal in ipairs(pedestals) do
        if pedestal.seed and first[pedestal.seed] then
            local picks = {{Emu.POOL.BOSS, Emu.extraBossPickSeed(pedestal.seed)}}
            if M.cycles(game) then
                picks[2] = {Emu.POOL.BOSS, Emu.altPickSeed(Emu.extraBossInitSeed(pedestal.seed))}
            end
            local items = state.emu:predictRoom(picks, options(state, game), true)
            if items[1] then return pedestal, items[1], items[2] ~= items[1] and items[2] or nil end
        end
    end
    return nil
end

function M.quality(id)
    local item = data and data.items[id]
    return item and item.q
end

return M
