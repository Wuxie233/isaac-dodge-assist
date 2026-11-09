-- Floor intelligence: the floor map, the items and loot seen in each room,
-- what unvisited rooms' layouts promise, and the floor score built from
-- them. Everything is read from the game; nothing here changes game state.
local FloorMap = include("floor_map")
local FloorScore = include("floor_score")
local RoomRewards = include("room_rewards")
local ItemForecast = include("item_forecast")
local PillInfo = include("pill_info")
local ChestForecast = include("chest_forecast")
local DropForecast = include("drop_forecast")
local RoomFeatures = include("room_features")
local ItemNotes = include("item_notes")
local SacrificeForecast = include("sacrifice_forecast")
local M = {}

function M.new()
    return {map = nil, items = {}, loot = {}, layout = {}, score = nil, page = 0,
        scanAt = -100, rewards = RoomRewards.new(), rocks = {}, forecast = nil, predicted = {}, forecastKey = nil}
end
-- A new run: fresh floor knowledge and a fresh copy of the item pools.
-- A continued run missed its earlier picks, so its forecast is approximate.
function M.startRun(state, game, continued)
    local fresh = M.new()
    fresh.page, fresh.statsPage = state.page, state.statsPage
    local ok, forecast = pcall(ItemForecast.start, game, not continued)
    if ok then fresh.forecast = forecast else fresh.forecastError = tostring(forecast) end
    return fresh
end
-- After a reload: the forecast keeps its pools under this core's code, and
-- an error the previous core's code ran into is tried again.
function M.adopt(state)
    ItemForecast.adopt(state.forecast)
    state.forecastKey, state.forecastError, state.forecastLogged = nil, nil, nil
    return state
end
-- A new floor: forget everything about the last one (the pools go on).
function M.newLevel(state)
    state.map, state.items, state.loot, state.layout, state.score = nil, {}, {}, {}, nil
    state.firstOnPedestal, state.contents, state.contentLoot, state.features = {}, {}, {}, {}
    state.predicted, state.forecastKey = {}, nil
    state.scanAt = -100
end
function M.newRoom(state, game)
    state.scanAt = -100
    state.pedestals, state.pills, state.cards, state.containers, state.bossNext = {}, {}, {}, {}, nil
    state.featLog = nil
    -- What the forecast promised for the room just entered, to be checked
    -- against the pedestals the log shows next (and the boss reward later).
    -- On a new floor this runs before newLevel, while the old floor's
    -- forecast is still here: the room's seed tells them apart.
    pcall(function()
        local desc = game:GetLevel():GetCurrentRoomDesc()
        local list = state.predicted and state.predicted[desc.ListIndex]
        if list and #list > 0 and list.spawnSeed == desc.SpawnSeed then
            local index = desc.ListIndex
            local words = {}
            for _, item in ipairs(list) do
                words[#words+1] = item.id .. ":" .. tostring(item.kind) .. (item.altOf and "/or" or "")
            end
            Isaac.DebugString("IAD FORECAST: room=" .. index .. " exact=" .. tostring(state.forecast and state.forecast.exact) ..
                " items=" .. table.concat(words, ","))
        end
    end)
    if state.forecast and not state.forecastError then
        local ok, err = pcall(ItemForecast.newRoom, state.forecast, game)
        if not ok then state.forecastError = tostring(err) end
    end
end
-- The game reported an item pick (MC_POST_GET_COLLECTIBLE).
function M.picked(state, item, pool, decrease) ItemForecast.picked(state.forecast, item, pool, decrease) end

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

-- Chests, sacks and alt rocks: what they give before anyone opens them
-- (chest_forecast.lua; native/research/chest-contents.md). Pure reads only:
-- the container's drop RNG seed, a grid's spawn seed, the players' items.

-- Vanilla Lua cannot read achievements. chest_forecast asks for them only
-- for rare kinds (golden pennies, rotten hearts...), so they count as
-- locked, except the Red Key's (415), which shows through item 580.
local function unlocked()
    local red = false
    pcall(function()
        local item = Isaac.GetItemConfig():GetCollectible(580)
        red = item ~= nil and item:IsAvailable()
    end)
    return function(id) return id == 415 and red end
end
-- One context for chests, sacks, alt rocks and room features (poops,
-- fireplaces, shopkeepers, reward plates, slots); player opens and pays.
local function contentsContext(game, player)
    local ok, ctx = pcall(DropForecast.readContext, game, unlocked())
    if not ok then return nil end
    if player then
        pcall(function()
            ctx.leftHand = player:GetTrinketMultiplier(61)
            ctx.payer = DropForecast.payerContext(player)
        end)
    end
    return ctx
end
-- What is not loot: {string key, bad}.
local EXTRAS = {["3.43"] = {"blueFlies"}, ["3.73"] = {"blueSpiders"}, ["4.4"] = {"trollBomb", true},
    ["4.3"] = {"trollBomb", true},
    ["18.0"] = {"attackFlies", true}, ["85.0"] = {"spiders", true}, ["0.1"] = {"teleport"}}
-- chest_forecast groups -> loot {kind = count} and extras {{key, count, bad}}.
local function contentsOf(groups)
    local loot, extras = {}, {}
    for _, g in ipairs(groups or {}) do
        if g.type == 5 then
            local kind = M.lootKind(g.variant, g.subtype)
            if kind then loot[kind] = (loot[kind] or 0) + g.count end
        else
            local extra = EXTRAS[g.type .. "." .. g.variant] or EXTRAS[g.type .. ".0"]
            if extra then extras[#extras+1] = {extra[1], g.count, extra[2]} end
        end
    end
    return loot, extras
end
-- A container's contents: {loot, extras, items = {{id, altOf}}, empty}.
local function containerContents(state, game, variant, subtype, seed, initSeed, ctx, roomPool, sameRoom)
    local r = ChestForecast.predict(variant, subtype, seed, ctx, initSeed)
    if not r then return nil end
    local loot, extras = contentsOf(r.groups)
    local items = {}
    if state.forecast and not state.forecastError and #r.items > 0 then
        local ok, list = pcall(ItemForecast.containerItems, state.forecast, game, r.items, roomPool, sameRoom,
            ChestForecast.DEVIL_SACRIFICE)
        if ok then items = list end
    end
    return {loot = loot, extras = extras, items = items, empty = r.empty}
end
local function addLoot(into, from)
    for kind, n in pairs(from) do into[kind] = (into[kind] or 0) + n end
end
-- A room feature's outcome (drop_forecast result) as contents: {loot,
-- extras, items, trinket, words = {{key, bad}}}; nil when it gives nothing.
local EFFECT_WORDS = {heal = {"fx_heal"}, trapdoor = {"fx_trapdoor"}, charge = {"fx_charge"},
    fart = {"fx_fart", true}, fly = {"fx_fly", true}, ["pretty fly"] = {"fx_prettyFly"},
    ["blue flies"] = {"fx_blueFlies"}, ["blue spiders"] = {"fx_blueSpiders"}}
local BAD_WORDS = {ambush = "fx_ambush", greed = "fx_greed", breaks = "fx_breaks", spiders = "rock_spiders"}
local function dropContents(state, game, r, roomPool, sameRoom)
    if not r or r.nothing then return nil end
    local loot, extras = contentsOf(r.groups)
    local words = {}
    if r.effect and EFFECT_WORDS[r.effect] then words[#words+1] = EFFECT_WORDS[r.effect] end
    if r.bad and BAD_WORDS[r.bad] then words[#words+1] = {BAD_WORDS[r.bad], true} end
    local picks = {}
    for _, it in ipairs(r.items or {}) do picks[#picks+1] = {pool = it.pool or roomPool, pickSeed = it.pickSeed} end
    local items = {}
    if r.fixedItem then items[#items+1] = {id = r.fixedItem} end
    if #picks > 0 and state.forecast and not state.forecastError then
        local ok, list = pcall(ItemForecast.containerItems, state.forecast, game, picks, nil, sameRoom)
        if ok then for _, it in ipairs(list) do items[#items+1] = it end end
    end
    -- A reward plate can give a golden poop or a chest: what they hold.
    if r.poop and not r.poop.nothing then addLoot(loot, (contentsOf(r.poop.groups))) end
    for _, chest in ipairs(r.chests or {}) do
        if chest.contents then addLoot(loot, (contentsOf(chest.contents.groups))) end
    end
    return {loot = loot, extras = extras, items = items, trinket = r.trinket, words = words}
end
-- A slot or beggar: which payment first pays out, and with what.
local SLOT_LOOK = 12
local function slotPrize(state, game, r, roomPool, sameRoom)
    if not r or r.unsupported or not r.firstPrize then return r and not r.unsupported and {none = true} or nil end
    local c = dropContents(state, game, r.payments[r.firstPrize], roomPool, sameRoom) or {loot = {}, extras = {}, items = {}, words = {}}
    c.nth = r.firstPrize
    return c
end

-- A sacrifice's outcome (sacrifice_forecast.lua) as contents for a label:
-- {loot, extras, items, words = {{key, bad}}, lead}.
local SAC_WORDS = {nothing = "sac_nothing", angelTeleport = "sac_teleport", trollBombs = "sac_trollBombs"}
local function sacrificeContents(state, game, o, ctx, roomPool, sameRoom)
    local c = {loot = {}, extras = {}, items = {}, words = {}}
    local function pick(pool, seed)
        if not (state.forecast and not state.forecastError) then return false end
        local ok, list = pcall(ItemForecast.containerItems, state.forecast, game, {{pool = pool, pickSeed = seed}}, nil, sameRoom)
        if ok and list[1] then c.items[#c.items+1] = list[1]; return true end
        return false
    end
    if o.kind == "penny" or o.kind == "coins" then c.loot.coin = o.coins or 1
    elseif o.kind == "bomb" then c.loot.bomb = 1
    elseif o.kind == "soulHeart" then
        c.loot.soul = 1
        if o.orRedemption then c.items[1] = {id = SacrificeForecast.REDEMPTION, altOf = SacrificeForecast.REDEMPTION} end
    elseif o.kind == "soulHearts" then c.loot.soul = 7
    elseif o.kind == "redemption" then c.items[1] = {id = o.fixedItem}
    elseif o.kind == "angelItem" then
        if not pick(o.item.pool, o.item.pickSeed) then c.lead = "sac_angelItem" end
    elseif o.kind == "angelChance" then c.words[1] = {o.angelChance >= 0.5 and "sac_angel50" or "sac_angel15"}
    elseif o.kind == "chest" then
        c.lead = "sac_chest"
        local held = o.chest and containerContents(state, game, o.chest.variant, o.chest.subtype, o.chest.seed,
            o.chest.seed, ctx, roomPool, sameRoom)
        if held then c.loot, c.extras, c.items = held.loot, held.extras, held.items end
    elseif o.kind == "boss" then c.words[1] = {o.boss == 271 and "sac_uriel" or "sac_gabriel", true}
    elseif o.kind == "darkRoom" then c.words[1] = {o.teleport == "start" and "sac_start" or "sac_darkRoom"}
    elseif SAC_WORDS[o.kind] then c.words[1] = {SAC_WORDS[o.kind], o.kind == "trollBombs"}
    end
    return c
end
-- The sacrifice context on top of the room-feature one. Redemption: the
-- item emulator knows whether the pools still hold it (nil when it cannot).
local function sacrificeContext(state, game, ctx, inRoom)
    local sctx = setmetatable({}, {__index = ctx})
    SacrificeForecast.addContext(sctx, game)
    if not inRoom then sctx.done = false end
    if sctx.redemptionAvailable == nil and state.forecast and not state.forecastError and state.forecast.exact then
        local ok, removed = pcall(function() return state.forecast.emu:isRemoved(SacrificeForecast.REDEMPTION) end)
        if ok then sctx.redemptionAvailable = not removed end
    end
    return sctx
end
-- The sacrifices worth a line in the room list, up to the 12th (at least
-- three ahead): an angel room teleport, an angel item or Redemption, the
-- Dark Room. At most two, first come first.
local SAC_NOTABLE = {angelTeleport = true, angelItem = true, redemption = true, darkRoom = true}
local function sacrificePrizes(state, game, seed, count, ctx, roomPool, sameRoom)
    local out = {}
    local list = SacrificeForecast.forecast(seed, count, ctx, math.max(3, 12 - count))
    for _, o in ipairs(list) do
        if SAC_NOTABLE[o.kind] and #out < 2 then
            local c = sacrificeContents(state, game, o, ctx, roomPool, sameRoom)
            c.key, c.nth = "sacrifice", o.n
            out[#out+1] = c
        end
    end
    return out
end

-- Item infos for the room's list, from a container's {id, altOf}.
local function chestItems(list, into)
    for _, item in ipairs(list) do
        local info = itemInfo(item.id)
        info.kind, info.predicted, info.altOf, info.price = "chest", true, item.altOf, 0
        into[#into+1] = info
    end
end

-- Room features still standing in the room the players are in: what each
-- gives (labels {x, y, ...contents, prefix}), the loot of those that drop
-- something when broken or put out, and their items. Also logs each one on
-- the first scan of a room (IAD FEAT) and every change after (IAD FEATX),
-- for checking the forecasts against the drops.
local POOP_GRID, PLATE_GRID, SPIKES_GRID = 14, 20, 8
local SANGUINE = 100
local SANGUINE_WORDS = {damage = "sang_damage", blackHearts = "sang_black", item = "sang_item",
    leviathan = "sang_leviathan"}
local function u32(n) return n and n & 0xFFFFFFFF or -1 end
local function featureScan(state, game, room, entities, ctx, roomPool, labels, loot, items, index)
    state.featLog = state.featLog or {}
    local logged = state.featLog
    local function log(key, sig, line)
        if logged[key] == sig then return end
        Isaac.DebugString((logged[key] == nil and "IAD FEAT " or "IAD FEATX ") .. line)
        logged[key] = sig
    end
    local function place(x, y, c, extra)
        if not c then return end
        c.x, c.y = x, y
        for k, v in pairs(extra or {}) do c[k] = v end
        labels[#labels+1] = c
    end
    local function take(c)
        if not c then return end
        addLoot(loot, c.loot)
        chestItems(c.items, items)
    end
    local poop = GridEntityType and GridEntityType.GRID_POOP or POOP_GRID
    local plate = GridEntityType and GridEntityType.GRID_PRESSURE_PLATE or PLATE_GRID
    local spikes = GridEntityType and GridEntityType.GRID_SPIKES or SPIKES_GRID
    local sacrificeRoom = room:GetType() == SacrificeForecast.ROOM_SACRIFICE
    for i = 0, room:GetGridSize() - 1 do
        local g = room:GetGridEntity(i)
        local t = g and g:GetType()
        if t == spikes and (sacrificeRoom or g:GetVariant() > SANGUINE) then
            -- What the next sacrifices give: the spike's own RNG (read,
            -- never advanced) and how many were made (VarData). Sanguine
            -- Bond's spikes in a devil room roll differently.
            local d = g:GetSaveState()
            local okSeed, seed = pcall(function() return g:GetRNG():GetSeed() end)
            seed = okSeed and seed or d.VariableSeed
            local count = g.VarData or d.VarData or 0
            local sctx = sacrificeContext(state, game, ctx, true)
            local label
            if g:GetVariant() > SANGUINE then
                local o = SacrificeForecast.sanguine(seed, sctx)
                log("s" .. i, u32(seed), string.format("sanguine g=%d seed=%d next=%s", i, u32(seed), o.kind))
                local c = {loot = {}, extras = {}, items = {}, words = {}}
                if o.kind == "coins" then c.loot.coin = 6
                else c.words[1] = {SANGUINE_WORDS[o.kind] or "sac_nothing"} end
                label = {sacrifice = {c}}
            else
                local list = SacrificeForecast.forecast(seed, count, sctx, 3)
                local kinds = {}
                for _, o in ipairs(list) do kinds[#kinds+1] = o.kind end
                log("s" .. i, count .. ":" .. u32(seed), string.format("sacrifice g=%d v=%d count=%d seed=%d done=%s next=%s",
                    i, g:GetVariant(), count, u32(seed), tostring(sctx.done), table.concat(kinds, ",")))
                local outcomes = {}
                for _, o in ipairs(list) do
                    local c = sacrificeContents(state, game, o, sctx, roomPool, true)
                    c.n = o.n
                    outcomes[#outcomes+1] = c
                end
                label = {sacrifice = outcomes, done = sctx.done}
                -- Kept for the room list after we leave.
                state.sacrificePrizes = state.sacrificePrizes or {}
                if index then state.sacrificePrizes[index] = sacrificePrizes(state, game, seed, count, sctx, roomPool, true) end
            end
            place(g.Position.X, g.Position.Y, label, {rock = true})
        elseif t == poop or (t == plate and g:GetVariant() == 1) then
            local d = g:GetSaveState()
            local v, st = g:GetVariant(), g.State
            log("g" .. i, st, string.format("g=%d t=%d v=%d st=%d ss=%d vd=%d", i, t, v, st, u32(d.SpawnSeed), d.VarData or 0))
            local r
            if t == poop and st < 1000 then
                if v == 9 then r = DropForecast.gigaPoop(d.SpawnSeed, st, ctx, d.VarData)
                elseif v < 7 or v > 10 then r = DropForecast.poop(v, d.SpawnSeed, ctx, d.VarData) end
            elseif t == plate and st == 0 then
                r = DropForecast.rewardPlate(d.SpawnSeed, ctx)
            end
            local c = r and dropContents(state, game, r, roomPool, true)
            take(c)
            place(g.Position.X, g.Position.Y, c, {rock = true})
        end
    end
    for _, e in ipairs(entities) do
        if e.Type == 33 or e.Type == 17 or e.Type == 6 then
            local okSeed, seed = pcall(function() return e:GetDropRNG():GetSeed() end)
            seed = okSeed and seed or e.InitSeed
            local alive = not e:IsDead() and (e.Type ~= 33 or e.HitPoints > 1)
            log("e" .. u32(e.InitSeed), tostring(alive) .. u32(seed), string.format("e=%d t=%d v=%d d=%d hp=%.1f",
                u32(e.InitSeed), e.Type, e.Variant, u32(seed), e.HitPoints))
            if alive then
                if e.Type == 6 then
                    local animation = e:GetSprite():GetAnimation()
                    if animation ~= "Broken" and animation ~= "Death" then
                        local payer = ctx.payer and setmetatable({}, {__index = ctx.payer}) or {}
                        payer.counter = DropForecast.slotCounter(e.Variant, e.InitSeed, seed, ctx)
                        local sctx = setmetatable({payer = payer}, {__index = ctx})
                        local r = DropForecast.slot(e.Variant, seed, sctx, SLOT_LOOK)
                        place(e.Position.X, e.Position.Y, slotPrize(state, game, r, roomPool, true))
                    end
                else
                    local noReward = false
                    pcall(function() noReward = e:HasEntityFlags(1 << 42) end)
                    local r = e.Type == 33 and DropForecast.fireplace(e.Variant, seed, ctx, noReward)
                        or DropForecast.shopkeeper(e.Variant, seed, ctx, noReward)
                    local c = dropContents(state, game, r, roomPool, true)
                    take(c)
                    place(e.Position.X, e.Position.Y, c)
                end
            end
        end
    end
end

-- The current room's items (kept once seen, also after being taken) and
-- what loot lies there now; unopened containers count as what they hold.
local function scanRoom(state, game, index, entities, rocks, player)
    local forecast = state.forecast
    -- Where the room's pedestals, pills and cards are, for the labels (shop
    -- ones too: what an unbought pill or card does).
    local pedestals, pills, cards, containers, contents = {}, {}, {}, {}, {}
    local ctx = contentsContext(game, player)
    local room = game:GetRoom()
    local okPool, roomPool = pcall(function() return ItemForecast.roomPool(room:GetType()) end)
    roomPool = okPool and roomPool or nil
    local items = state.items[index] or {}
    local seen = {}
    for _, item in ipairs(items) do seen[item.id] = true end
    -- The item each pedestal (by InitSeed) showed first. A cycling pedestal
    -- (Tainted Isaac, Glitched Crown) shows its others in turn: they are
    -- one choice, altOf the first.
    state.firstOnPedestal = state.firstOnPedestal or {}
    local first = state.firstOnPedestal[index] or {}
    state.firstOnPedestal[index] = first
    local loot = {}
    -- Who could take a pedestal's item, for its transformation and
    -- Spindown notes.
    local okPeople, people = pcall(ItemNotes.players, game)
    people = okPeople and people or nil
    for _, e in ipairs(entities) do
        local pickup = e.Type == EntityType.ENTITY_PICKUP and e.ToPickup and e:ToPickup()
        if pickup then
            if PickupVariant and pickup.Variant == PickupVariant.PICKUP_COLLECTIBLE then
                if pickup.SubType > 0 then
                    ItemForecast.seen(forecast, pickup.SubType)
                    local okNotes, notes = false, nil
                    if people then okNotes, notes = pcall(ItemNotes.notes, pickup.SubType, game, people) end
                    pedestals[#pedestals+1] = {x = pickup.Position.X, y = pickup.Position.Y, id = pickup.SubType,
                        price = pickup.Price or 0, seed = pickup.InitSeed and pickup.InitSeed & 0xFFFFFFFF,
                        notes = okNotes and notes or nil}
                end
                local seed = pickup.InitSeed and pickup.InitSeed & 0xFFFFFFFF
                if pickup.SubType > 0 and not seen[pickup.SubType] then
                    local info = itemInfo(pickup.SubType)
                    info.price = pickup.Price or 0
                    info.devil = (pickup.Price or 0) < 0
                    if seed and first[seed] and first[seed] ~= pickup.SubType then info.altOf = first[seed] end
                    items[#items+1], seen[pickup.SubType] = info, true
                end
                if seed and pickup.SubType > 0 and not first[seed] then first[seed] = pickup.SubType end
            else
                if PickupVariant and pickup.Variant == PickupVariant.PICKUP_PILL and pickup.SubType > 0 then
                    local ok, effect, horse = pcall(PillInfo.effect, game, pickup.SubType, player)
                    pills[#pills+1] = {x = pickup.Position.X, y = pickup.Position.Y, effect = ok and effect or nil, horse = ok and horse}
                elseif PickupVariant and pickup.Variant == PickupVariant.PICKUP_TAROTCARD and pickup.SubType > 0 then
                    cards[#cards+1] = {x = pickup.Position.X, y = pickup.Position.Y, id = pickup.SubType}
                end
                -- An unopened chest or sack: its drop RNG is still at its
                -- InitSeed state; GetSeed only reads it.
                local held
                if ctx and ChestForecast.isContainer(pickup.Variant) then
                    local okSeed, seed = pcall(function() return pickup:GetDropRNG():GetSeed() end)
                    local ok, c = pcall(containerContents, state, game, pickup.Variant, pickup.SubType,
                        okSeed and seed or pickup.InitSeed, pickup.InitSeed, ctx, roomPool, true)
                    if ok and c then
                        held = c
                        c.x, c.y = pickup.Position.X, pickup.Position.Y
                        containers[#containers+1] = c
                    end
                end
                if (pickup.Price or 0) == 0 then
                    if held then
                        addLoot(loot, held.loot)
                        chestItems(held.items, contents)
                    else
                        local kind = M.lootKind(pickup.Variant, pickup.SubType)
                        if kind then loot[kind] = (loot[kind] or 0) + 1 end
                    end
                end
            end
        end
    end
    for _, rock in ipairs(rocks) do
        local kind = rock.label == "gold" and "goldrock" or rock.label
        loot[kind] = (loot[kind] or 0) + 1
        -- An alt rock (urn, mushroom, skull, polyp, bucket) rolls on its
        -- spawn seed when it breaks: label what it drops, or what it lets out.
        if ctx and (rock.label == "alt" or rock.label == "skull") then
            local ok, r = pcall(function()
                local grid = room:GetGridEntity(rock.index)
                local rctx = setmetatable({roomType = room:GetType(), luckyRock = ctx.trinkets and ctx.trinkets[15],
                    isRemoved = state.forecast and function(id) return state.forecast.emu:isRemoved(id) end or nil},
                    {__index = ctx})
                return ChestForecast.rock(grid:GetType(), room:GetBackdropType(), grid:GetSaveState().SpawnSeed, rctx)
            end)
            if ok and r and not r.nothing then
                local rockLoot, extras = contentsOf(r.groups)
                containers[#containers+1] = {x = rock.x, y = rock.y, loot = rockLoot, extras = extras, rock = true,
                    items = r.item and {{id = r.item}} or {}, trinket = r.trinket, bad = r.bad}
            end
        end
    end
    if ctx then
        local ok, err = pcall(featureScan, state, game, room, entities, ctx, roomPool, containers, loot, contents, index)
        if not ok and not state.featureErrorLogged then
            state.featureErrorLogged = true
            Isaac.DebugString("IAD INTEL: features " .. tostring(err))
        end
    end
    state.items[index], state.loot[index], state.rocks[index] = items, loot, #rocks
    state.features = state.features or {}
    local okFeatures, features = pcall(RoomFeatures.scan, room, entities)
    if okFeatures then state.features[index] = features end
    state.pedestals, state.pills, state.cards, state.containers = pedestals, pills, cards, containers
    state.contents = state.contents or {}
    state.contents[index] = #contents > 0 and contents or nil
end

-- Every update: reward rocks for the overlay; room and floor rescans every
-- RESCAN updates (and right after entering a room).
local RESCAN = 15
-- Floor readouts the game's own HUD also shows: deal and planetarium
-- chances, and the time gates for Boss Rush (20:00) and Hush (30:00).
-- {deal, planetarium (percent), seconds}; a field the game did not give
-- stays nil.
local function readouts(game, level)
    local out = {}
    pcall(function() out.deal = math.floor(math.min(1, game:GetRoom():GetDevilRoomChance())*100 + 0.5) end)
    pcall(function() out.planetarium = math.floor(level:GetPlanetariumChance()*100 + 0.5) end)
    pcall(function() out.seconds = math.floor(game.TimeCounter / 30) end)
    return out
end
M.RUSH, M.HUSH = 1200, 1800 -- Boss Rush and Hush time gates, seconds

-- What the players can open and pay for (FloorScore.access): the most
-- keys/bombs/coins any player holds (golden ones count as plenty), bomb
-- tears (Dr. Fetus, Epic Fetus), and the red-door tools: Red Key, Cracked
-- Key, Soul of Cain, The Moon? (held, or merely unlocked in this save).
local RED_KEY, BOMB_ITEMS = 580, {52, 168}
local RED_CARDS = {78, 83, 74}
local function accessOf(game, level)
    local a = {keys = 0, bombs = 0, coins = 0, stage = 1, redHeld = false, redUnlocked = false,
        players = ItemForecast.players(game)}
    pcall(function() a.stage = level:GetStage() end)
    for i = 0, game:GetNumPlayers() - 1 do
        local p = Isaac.GetPlayer(i)
        a.keys = math.max(a.keys, p:GetNumKeys() + (p:HasGoldenKey() and 99 or 0))
        a.bombs = math.max(a.bombs, p:GetNumBombs() + (p:HasGoldenBomb() and 99 or 0))
        a.coins = math.max(a.coins, p:GetNumCoins())
        for _, id in ipairs(BOMB_ITEMS) do if p:HasCollectible(id) then a.bombs = 99 end end
        if p:HasCollectible(RED_KEY) then a.redHeld = true end
        for slot = 0, 1 do
            local card = p:GetCard(slot)
            for _, id in ipairs(RED_CARDS) do if card == id then a.redHeld = true end end
        end
    end
    pcall(function()
        local config = Isaac.GetItemConfig()
        local key = config:GetCollectible(RED_KEY)
        a.redUnlocked = a.redHeld or (key ~= nil and key:IsAvailable())
        for _, id in ipairs(RED_CARDS) do
            local card = config:GetCard(id)
            if card and card:IsAvailable() then a.redUnlocked = true end
        end
    end)
    return a
end

-- Items forecast for every unvisited room, redone when the pools or the
-- floor changed. Returns how far the forecast can be trusted: "exact",
-- "approx", or "off" and why.
local function forecastRooms(state, game)
    local blocked = ItemForecast.blocked(game)
    if blocked then state.predicted = {}; return "off", blocked end
    local forecast = state.forecast
    local key = forecast.version .. ":" .. #state.map.rooms
    if key ~= state.forecastKey then
        state.forecastKey = key
        state.predicted, state.contentLoot, state.slotPrizes = {}, {}, {}
        local ctx
        for _, room in ipairs(state.map.rooms) do
            if not room.visited then
                -- One odd room must not cost the others their forecast.
                local ok, list = pcall(ItemForecast.room, forecast, game, room)
                if not ok and not state.roomErrorLogged then
                    state.roomErrorLogged = true
                    Isaac.DebugString("IAD INTEL: forecast room " .. tostring(room.type) .. "." .. tostring(room.variant) .. " " .. tostring(list))
                end
                list = ok and list or {}
                for _, item in ipairs(list) do
                    local info = itemInfo(item.id)
                    info.kind, info.predicted, info.altOf = item.kind, true, item.altOf
                    info.devil = room.type == 14 and item.kind == "shop"
                    info.price = item.kind == "shop" and 1 or 0
                    list[_] = info
                end
                -- A chest or sack the layout always places: its InitSeed
                -- (as a pedestal's) decides its kind and what it holds.
                local layout = room.layout
                -- A sacrifice room: what its spikes give, from the layout
                -- spawn's seed, as prizes in the room list.
                if layout and layout.sacrifice and room.type == SacrificeForecast.ROOM_SACRIFICE then
                    ctx = ctx or contentsContext(game, nil)
                    if ctx then
                        pcall(function()
                            local sctx = sacrificeContext(state, game, ctx, false)
                            local first = SacrificeForecast.initialRngSeed(SacrificeForecast.layoutSeed(room.spawnSeed, layout.sacrifice))
                            local prizes = sacrificePrizes(state, game, first, 0, sctx, nil, false)
                            if #prizes > 0 then state.slotPrizes[room.index] = prizes end
                        end)
                    end
                end
                local hasFeatures = layout and layout.featureSpawns and #layout.featureSpawns > 0
                if layout and ((layout.containers and #layout.containers > 0) or hasFeatures) then
                    ctx = ctx or contentsContext(game, nil)
                    local loot = {}
                    for kind, n in pairs(layout.loot) do loot[kind] = n end
                    -- Poops, fireplaces, shopkeepers and reward plates the
                    -- layout surely places: what breaking them gives; a
                    -- slot or beggar: its first prize (counter at 0).
                    for _, f in ipairs(ctx and layout.featureSpawns or {}) do
                        pcall(function()
                            local r = DropForecast.forLayout(f.type, f.variant, room.spawnSeed, f.index, ctx)
                            if not r then return end
                            local pool = ItemForecast.roomPool(room.type)
                            if r.payments then
                                local prize = slotPrize(state, game, r, pool, false)
                                if prize then
                                    prize.key = RoomFeatures.fromLayout(6, r.variant or f.variant, 0) or f.key
                                    local prizes = state.slotPrizes[room.index] or {}
                                    prizes[#prizes+1] = prize
                                    state.slotPrizes[room.index] = prizes
                                end
                            else
                                local c = dropContents(state, game, r, pool, false)
                                if c then
                                    addLoot(loot, c.loot)
                                    chestItems(c.items, list)
                                end
                            end
                        end)
                    end
                    for _, c in ipairs(ctx and layout.containers or {}) do
                        pcall(function()
                            local init = ItemForecast.layoutInitSeed(room.spawnSeed, c.index)
                            local v, sub = c.variant, c.subtype
                            if sub == 0 then v, sub = ChestForecast.resolve(v, init, ctx) end
                            if v ~= 69 and sub == 0 then sub = 1 end -- spawns closed
                            local held = containerContents(state, game, v, sub, init, init, ctx,
                                ItemForecast.roomPool(room.type), false)
                            if held then
                                if c.kind and loot[c.kind] then
                                    loot[c.kind] = loot[c.kind] - 1
                                    if loot[c.kind] <= 1e-9 then loot[c.kind] = nil end
                                end
                                addLoot(loot, held.loot)
                                chestItems(held.items, list)
                            end
                        end)
                    end
                    state.contentLoot[room.index] = loot
                end
                if #list > 0 then
                    list.spawnSeed = room.spawnSeed
                    state.predicted[room.index] = list
                end
            end
        end
    end
    return forecast.exact and "exact" or "approx"
end

-- entities: a function returning the room's entities (called only to scan).
-- player: the bound player (pills read as that player would take them).
function M.update(state, game, room, entities, frame, player)
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
    -- How many items each boss room drops (one per person; none after a
    -- chapter's last boss), for the score's estimate of what is unseen.
    for _, r in ipairs(state.map.rooms) do
        if r.type == 5 then
            local ok, n = pcall(ItemForecast.bossItems, game, r)
            if ok then r.rewards = n end
        end
    end
    -- A core loaded in the middle of a run never saw its start. The
    -- forecast is an extra on top of the map: if it fails, it is off and
    -- says why, and everything else goes on.
    if not state.forecast and not state.forecastError then
        local ok, forecast = pcall(ItemForecast.start, game, false)
        if ok then state.forecast = forecast else state.forecastError = tostring(forecast) end
    end
    if state.map.current then scanRoom(state, game, state.map.current, entities(), rocks, player) end
    local status, reason = "off", "error"
    if state.forecast and not state.forecastError then
        local ok, result, why = pcall(forecastRooms, state, game)
        if ok then status, reason = result, why else state.forecastError, state.predicted = tostring(result), {} end
    end
    -- Co-op, cleared boss room: the next person's item, on the first
    -- pedestal's tooltip and in the score until it is on the floor itself.
    state.bossNext = nil
    if status ~= "off" then
        for _, room in ipairs(state.map.rooms) do
            if room.index == state.map.current then
                local ok, pedestal, id, second = pcall(ItemForecast.bossNext, state.forecast, game, room, state.pedestals or {})
                if ok and pedestal then
                    pedestal.next, pedestal.nextOr = id, second
                    local info = itemInfo(id)
                    info.kind, info.predicted = "boss", true
                    local extra = {info}
                    if second then
                        local other = itemInfo(second)
                        other.kind, other.predicted, other.altOf = "boss", true, id
                        extra[2] = other
                    end
                    state.bossNext = {index = room.index, list = extra}
                end
            end
        end
    end
    if state.forecastError and not state.forecastLogged then
        state.forecastLogged = true
        Isaac.DebugString("IAD INTEL: forecast error " .. state.forecastError)
    end
    local okAccess, access = pcall(accessOf, game, level)
    -- What is promised but not on the floor yet joins the room's items:
    -- the next co-op boss item, and what unopened chests hold.
    local items = state.items
    local promised = {}
    if state.bossNext then promised[state.bossNext.index] = state.bossNext.list end
    for index, list in pairs(state.contents or {}) do
        local into = promised[index] or {}
        for _, info in ipairs(list) do into[#into+1] = info end
        promised[index] = into
    end
    local view = {}
    for index, extra in pairs(promised) do
        local list, present = {}, {}
        for _, item in ipairs(state.items[index] or {}) do
            list[#list+1] = item
            present[item.id] = true
        end
        for _, info in ipairs(extra) do
            if not present[info.id] then list[#list+1], present[info.id] = info, true end
        end
        view[index] = list
    end
    if next(view) then items = setmetatable(view, {__index = state.items}) end
    -- An unvisited room's loot with its chests counted as what they hold;
    -- a visited room's features as last seen standing.
    for _, r in ipairs(state.map.rooms) do
        if not r.visited and state.contentLoot then r.contentLoot = state.contentLoot[r.index] end
        if not r.visited and state.slotPrizes then r.slotPrizes = state.slotPrizes[r.index] end
        -- A sacrifice room seen: its spikes' next notable payouts.
        if r.visited and state.sacrificePrizes and state.sacrificePrizes[r.index] then
            r.slotPrizes, r.keepPrizes = state.sacrificePrizes[r.index], true
        end
        if r.visited and state.features then r.features = state.features[r.index] end
    end
    state.score = FloorScore.evaluate(state.map.rooms, items, state.loot, state.predicted, okAccess and access or nil)
    state.readouts = readouts(game, level)
    state.readouts.forecast, state.readouts.forecastWhy = status, reason
    pcall(function() state.readouts.stage = level:GetStage() end)
    return rocks
end

function M.extras(state)
    local extras = {}
    for index, items in pairs(state.items) do extras[index] = {items = #items} end
    for index, items in pairs(state.predicted or {}) do
        extras[index] = extras[index] or {}
        extras[index].forecast = #items
    end
    for index, n in pairs(state.rocks) do
        extras[index] = extras[index] or {}
        extras[index].rocks = n
    end
    return extras
end

return M
