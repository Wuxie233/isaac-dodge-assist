-- Floor intelligence: the floor map, the items and loot seen in each room,
-- what unvisited rooms' layouts promise, and the floor score built from
-- them. Everything is read from the game; nothing here changes game state.
local FloorMap = include("floor_map")
local FloorScore = include("floor_score")
local RoomRewards = include("room_rewards")
local M = {}

function M.new()
    return {map = nil, items = {}, loot = {}, layout = {}, score = nil, showMap = false,
        scanAt = -100, rewards = RoomRewards.new(), rocks = {}}
end
-- A new floor (or run): forget everything about the last one.
function M.newLevel(state)
    state.map, state.items, state.loot, state.layout, state.score = nil, {}, {}, {}, nil
    state.scanAt = -100
end
function M.newRoom(state) state.scanAt = -100 end

-- Pickup kinds counted as loot, by PickupVariant name.
local LOOT = {PICKUP_KEY = "key", PICKUP_BOMB = "bomb", PICKUP_PILL = "pill", PICKUP_TAROTCARD = "card",
    PICKUP_LIL_BATTERY = "battery", PICKUP_TRINKET = "trinket", PICKUP_GRAB_BAG = "sack",
    PICKUP_CHEST = "chest", PICKUP_BOMBCHEST = "chest", PICKUP_SPIKEDCHEST = "chest",
    PICKUP_ETERNALCHEST = "chest", PICKUP_WOODENCHEST = "chest", PICKUP_REDCHEST = "chest",
    PICKUP_MEGACHEST = "gold", PICKUP_LOCKEDCHEST = "gold", PICKUP_HAUNTEDCHEST = "chest"}
-- Coins and hearts by SubType: CoinSubType / HeartSubType names.
local COIN = {COIN_PENNY = "coin", COIN_DOUBLEPACK = "coin", COIN_NICKEL = "nickel", COIN_STICKYNICKEL = "nickel",
    COIN_DIME = "dime", COIN_LUCKYPENNY = "nickel", COIN_GOLDEN = "nickel"}
local HEART = {HEART_SOUL = "soul", HEART_BLACK = "soul", HEART_ETERNAL = "soul", HEART_BONE = "soul",
    HEART_HALF_SOUL = "heart", HEART_GOLDEN = "heart", HEART_BLENDED = "soul"}
local lootByVariant, coinBySub, heartBySub
local function lookups()
    if lootByVariant then return end
    lootByVariant, coinBySub, heartBySub = {}, {}, {}
    for name, kind in pairs(LOOT) do if PickupVariant and PickupVariant[name] then lootByVariant[PickupVariant[name]] = kind end end
    for name, kind in pairs(COIN) do if CoinSubType and CoinSubType[name] then coinBySub[CoinSubType[name]] = kind end end
    for name, kind in pairs(HEART) do if HeartSubType and HeartSubType[name] then heartBySub[HeartSubType[name]] = kind end end
end
-- Loot kind of a pickup (variant, subtype), or nil.
function M.lootKind(variant, subtype)
    lookups()
    if not PickupVariant then return nil end
    if variant == PickupVariant.PICKUP_COIN then return coinBySub[subtype] or "coin" end
    if variant == PickupVariant.PICKUP_HEART then return heartBySub[subtype] or "heart" end
    return lootByVariant[variant]
end

-- Item names come back as localisation keys ("#THE_SAD_ONION_NAME");
-- the key spells the English name well enough ("The Sad Onion").
function M.readableName(name)
    if type(name) ~= "string" then return nil end
    if name:sub(1, 1) ~= "#" then return name end
    local words = {}
    for word in name:sub(2):gsub("_NAME$", ""):gmatch("[^_]+") do
        words[#words+1] = word:sub(1, 1) .. word:sub(2):lower()
    end
    return #words > 0 and table.concat(words, " ") or nil
end
local function itemInfo(id)
    local name, quality
    pcall(function()
        local config = Isaac.GetItemConfig():GetCollectible(id)
        if config then quality, name = config.Quality, config.Name end
    end)
    return {id = id, quality = quality or 1, name = M.readableName(name)}
end

-- The current room's items (kept once seen, also after being taken) and
-- what loot lies there now.
local function scanRoom(state, index, entities, rocks)
    local items = state.items[index] or {}
    local seen = {}
    for _, item in ipairs(items) do seen[item.id] = true end
    local loot = {}
    for _, e in ipairs(entities) do
        local pickup = e.Type == EntityType.ENTITY_PICKUP and e.ToPickup and e:ToPickup()
        if pickup then
            if PickupVariant and pickup.Variant == PickupVariant.PICKUP_COLLECTIBLE then
                if pickup.SubType > 0 and not seen[pickup.SubType] then
                    local info = itemInfo(pickup.SubType)
                    info.price = pickup.Price or 0
                    info.devil = (pickup.Price or 0) < 0
                    items[#items+1], seen[pickup.SubType] = info, true
                end
            elseif (pickup.Price or 0) == 0 then
                local kind = M.lootKind(pickup.Variant, pickup.SubType)
                if kind then loot[kind] = (loot[kind] or 0) + 1 end
            end
        end
    end
    for _, rock in ipairs(rocks) do
        local kind = rock.label == "gold" and "goldrock" or rock.label
        loot[kind] = (loot[kind] or 0) + 1
    end
    state.items[index], state.loot[index], state.rocks[index] = items, loot, #rocks
end

-- Every update: reward rocks for the overlay; room and floor rescans every
-- RESCAN updates (and right after entering a room).
local RESCAN = 15
-- Floor readouts the game's own HUD also shows: deal and planetarium
-- chances, and the time gates for Boss Rush (20:00) and Hush (30:00).
local function readouts(game, level)
    local parts = {}
    pcall(function() parts[#parts+1] = string.format("deal %d%%", math.floor(math.min(1, game:GetRoom():GetDevilRoomChance())*100 + 0.5)) end)
    pcall(function() parts[#parts+1] = string.format("planetarium %d%%", math.floor(level:GetPlanetariumChance()*100 + 0.5)) end)
    pcall(function()
        local seconds = math.floor(game.TimeCounter / 30)
        local function left(limit)
            local rest = limit - seconds
            return rest > 0 and string.format("%d:%02d", rest // 60, rest % 60) or "closed"
        end
        parts[#parts+1] = string.format("time %d:%02d  rush %s  hush %s", seconds // 60, seconds % 60, left(1200), left(1800))
    end)
    return table.concat(parts, "  ")
end

-- entities: a function returning the room's entities (called only to scan).
function M.update(state, game, room, entities, frame)
    local rocks = RoomRewards.update(state.rewards, room, frame)
    if frame - state.scanAt < RESCAN and frame >= state.scanAt then return rocks end
    state.scanAt = frame
    local level = game:GetLevel()
    -- Unvisited rooms: what their layout places, read once per room.
    local function layoutOf(index, desc)
        if state.layout[index] == nil then
            local ok, layout = pcall(FloorMap.layout, desc, M.lootKind)
            state.layout[index] = ok and layout or false
        end
        return state.layout[index] or nil
    end
    state.map = FloorMap.scan(level, layoutOf)
    if state.map.current then scanRoom(state, state.map.current, entities(), rocks) end
    state.score = FloorScore.evaluate(state.map.rooms, state.items, state.loot)
    state.score.lines[#state.score.lines+1] = {readouts(game, level), {0.75, 0.75, 0.8}}
    return rocks
end

function M.extras(state)
    local extras = {}
    for index, items in pairs(state.items) do extras[index] = {items = #items} end
    for index, n in pairs(state.rocks) do
        extras[index] = extras[index] or {}
        extras[index].rocks = n
    end
    return extras
end

return M
