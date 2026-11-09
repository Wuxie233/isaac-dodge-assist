-- Notes on a pedestal's tooltip that depend on the players: how far each
-- one is toward the transformations the item counts for (who should take
-- it), and, while someone holds the Spindown Dice, what the next turns of
-- it make of the item. Read only: tags, Hidden and availability from
-- ItemConfig, counters and held items from the players.
local M = {}

-- Transformations counted by item tags (items_metadata.xml), three items
-- each: tag name in ItemConfig, its bit, PlayerForm name and value. Adult
-- and Stompy come from pills, Super Bum from three given familiars.
M.FORMS = {
    {key = "guppy", tag = "TAG_GUPPY", bit = 1 << 5, form = "PLAYERFORM_GUPPY", value = 0},
    {key = "fly", tag = "TAG_FLY", bit = 1 << 6, form = "PLAYERFORM_LORD_OF_THE_FLIES", value = 1},
    {key = "mushroom", tag = "TAG_MUSHROOM", bit = 1 << 8, form = "PLAYERFORM_MUSHROOM", value = 2},
    {key = "angel", tag = "TAG_ANGEL", bit = 1 << 10, form = "PLAYERFORM_ANGEL", value = 3},
    {key = "bob", tag = "TAG_BOB", bit = 1 << 7, form = "PLAYERFORM_BOB", value = 4},
    {key = "syringe", tag = "TAG_SYRINGE", bit = 1 << 1, form = "PLAYERFORM_DRUGS", value = 5},
    {key = "mom", tag = "TAG_MOM", bit = 1 << 2, form = "PLAYERFORM_MOM", value = 6},
    {key = "baby", tag = "TAG_BABY", bit = 1 << 9, form = "PLAYERFORM_BABY", value = 7},
    {key = "devil", tag = "TAG_DEVIL", bit = 1 << 11, form = "PLAYERFORM_EVIL_ANGEL", value = 8},
    {key = "poop", tag = "TAG_POOP", bit = 1 << 12, form = "PLAYERFORM_POOP", value = 9},
    {key = "book", tag = "TAG_BOOK", bit = 1 << 13, form = "PLAYERFORM_BOOK_WORM", value = 10},
    {key = "spider", tag = "TAG_SPIDER", bit = 1 << 14, form = "PLAYERFORM_SPIDERBABY", value = 12},
}
M.FORM_ITEMS = 3
local TAG_NO_GREED, TAG_NO_CHALLENGE = 1 << 17, 1 << 28
local SPINDOWN, CAR_BATTERY, DADS_NOTE = 723, 356, 668
M.SPINDOWN_STEPS = 3

local function enum(t, name, fallback) return t and t[name] or fallback end
local function itemConfig()
    return Isaac.GetItemConfig and Isaac.GetItemConfig() or nil
end
local function hasTag(config, tag, bit)
    local value = enum(ItemConfig, tag, bit)
    if config.HasTags then return config:HasTags(value) end
    return config.Tags ~= nil and config.Tags & value ~= 0
end

-- One player per person (the first entity of each controller: Jacob and
-- Esau, The Forgotten's soul share it), in player order: {player, number}.
function M.players(game)
    local out, seen = {}, {}
    for i = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(i)
        local controller = player.ControllerIndex or i
        if not seen[controller] then
            seen[controller] = true
            out[#out+1] = {player = player, number = i + 1}
        end
    end
    return out
end

-- {{key, counts = {{number, count, done}}}} for each transformation the
-- item counts toward; nil when none.
function M.forms(id, people)
    local config = itemConfig()
    config = config and config:GetCollectible(id)
    if not config then return nil end
    local out
    for _, f in ipairs(M.FORMS) do
        if hasTag(config, f.tag, f.bit) then
            local form = enum(PlayerForm, f.form, f.value)
            local counts = {}
            for _, p in ipairs(people) do
                local player = p.player
                local count = player.GetPlayerFormCounter and player:GetPlayerFormCounter(form) or 0
                local done = player.HasPlayerForm and player:HasPlayerForm(form) or false
                counts[#counts+1] = {p.number, count, done}
            end
            out = out or {}
            out[#out+1] = {key = f.key, counts = counts}
        end
    end
    return out
end

-- The item Spindown Dice turns id into: the next lower id that exists, is
-- not hidden, is unlocked and allowed in this mode (0 when none).
function M.spinOnce(id, game)
    local config = itemConfig()
    if not config then return 0 end
    local greed = game.IsGreedMode and game:IsGreedMode()
    local challenge = (game.Challenge or 0) > 0
    for _ = 1, 32 do
        id = id - 1
        if id <= 0 then return 0 end
        local c = config:GetCollectible(id)
        if c and not c.Hidden and (not c.IsAvailable or c:IsAvailable())
            and not (greed and hasTag(c, "TAG_NO_GREED", TAG_NO_GREED))
            and not (challenge and hasTag(c, "TAG_NO_CHALLENGE", TAG_NO_CHALLENGE)) then
            return id
        end
    end
    return 0
end

-- While a player holds the Spindown Dice: the items its next uses leave on
-- the pedestal ({ids}, carBattery), each use two steps with Car Battery.
-- Dad's Note is never changed, so the chain stops there. nil otherwise.
function M.spindown(id, game, people)
    local holder
    for _, p in ipairs(people) do
        if p.player.HasCollectible and p.player:HasCollectible(SPINDOWN) then holder = p.player; break end
    end
    if not holder or id == DADS_NOTE then return nil end
    local battery = holder:HasCollectible(CAR_BATTERY)
    local ids = {}
    for _ = 1, M.SPINDOWN_STEPS do
        id = M.spinOnce(id, game)
        if battery and id > 0 and id ~= DADS_NOTE then id = M.spinOnce(id, game) end
        ids[#ids+1] = id
        if id == 0 or id == DADS_NOTE then break end
    end
    return {ids = ids, carBattery = battery}
end

-- Both notes for one pedestal, or nil.
function M.notes(id, game, people)
    local forms = M.forms(id, people)
    local spin = M.spindown(id, game, people)
    if not forms and not spin then return nil end
    return {forms = forms, spin = spin}
end

return M
