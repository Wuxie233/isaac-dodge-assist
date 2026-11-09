-- What a room has besides pickups: beggars and machines, shopkeepers,
-- fireplaces, poops and reward plates. Read from an unvisited room's
-- layout (Data.Spawns entries, STB codes) or from the room the players are
-- in (entities and grids still standing). Names in both languages, a rough
-- worth for the floor score, and whether it makes an ordinary room worth a
-- line in the room list. Read only.
local M = {}

-- key -> {en, zh, value, notable}. What breaking a poop, putting out a
-- fire, killing a shopkeeper or pressing a reward plate gives is forecast
-- (drop_forecast.lua) and counted as loot, so those carry no value here.
M.KINDS = {
    slot1 = {"slot machine", "老虎机", 1, true}, slot2 = {"blood donation", "献血机", 1, true},
    slot3 = {"fortune teller", "算命机", 0.5, true}, slot4 = {"beggar", "乞丐", 1.5, true},
    slot5 = {"devil beggar", "恶魔乞丐", 2, true}, slot6 = {"shell game", "猜壳游戏", 1, true},
    slot7 = {"key master", "钥匙大师", 1.5, true}, slot8 = {"donation machine", "捐款机", 0, true},
    slot9 = {"bomb bum", "炸弹乞丐", 1.5, true}, slot10 = {"restock machine", "补货机", 1.5, true},
    slot11 = {"greed donation", "贪婪捐款机", 0, true}, slot12 = {"dressing table", "梳妆台", 0.5, true},
    slot13 = {"battery bum", "电池乞丐", 1.5, true}, slot15 = {"hell game", "地狱游戏", 1, true},
    slot16 = {"crane game", "抓娃娃机", 1.5, true}, slot17 = {"confessional", "忏悔室", 1, true},
    slot18 = {"rotten beggar", "腐烂乞丐", 1.5, true},
    shopkeeper = {"shopkeeper", "店主", 0, false},
    fire = {"fireplace", "火堆", 0, false}, redFire = {"red fireplace", "红火堆", 0, false},
    blueFire = {"blue fireplace", "蓝火堆", 0, false}, purpleFire = {"purple fireplace", "紫火堆", 0, false},
    whiteFire = {"white fireplace", "白火堆", 1, true},
    poop = {"poop", "便便", 0, false}, redPoop = {"red poop", "红便便", 0, false},
    cornyPoop = {"corny poop", "玉米便便", 0, false}, goldenPoop = {"golden poop", "金便便", 0, true},
    rainbowPoop = {"rainbow poop", "彩虹便便", 1, true}, blackPoop = {"black poop", "黑便便", 0.5, true},
    whitePoop = {"white poop", "白便便", 0, true}, gigaPoop = {"giga poop", "巨型便便", 1, true},
    charmingPoop = {"charming poop", "魅惑便便", 0.5, true},
    rewardPlate = {"reward plate", "奖励按钮", 0, true},
}
-- Order the words come in.
M.ORDER = {"slot4", "slot5", "slot7", "slot9", "slot13", "slot18", "slot1", "slot2", "slot3", "slot6",
    "slot15", "slot16", "slot17", "slot10", "slot12", "slot8", "slot11", "rewardPlate", "goldenPoop",
    "rainbowPoop", "whitePoop", "gigaPoop", "blackPoop", "charmingPoop", "cornyPoop", "redPoop", "poop",
    "shopkeeper", "whiteFire", "blueFire", "purpleFire", "redFire", "fire"}

-- Layout codes (STB): grid poops 1490-1501, grid fireplaces 1400/1410,
-- pressure plate 4500 (variant 1 = reward plate).
local LAYOUT_GRID = {[1490] = "redPoop", [1494] = "rainbowPoop", [1495] = "cornyPoop", [1496] = "goldenPoop",
    [1497] = "blackPoop", [1498] = "whitePoop", [1499] = "gigaPoop", [1500] = "poop", [1501] = "charmingPoop",
    [1400] = "fire", [1410] = "redFire"}
-- Fireplace (entity 33) and grid poop variants.
local FIRES = {[0] = "fire", [1] = "redFire", [2] = "blueFire", [3] = "purpleFire", [4] = "whiteFire"}
local POOPS = {[0] = "poop", [1] = "redPoop", [2] = "cornyPoop", [3] = "goldenPoop", [4] = "rainbowPoop",
    [5] = "blackPoop", [6] = "whitePoop", [7] = "gigaPoop", [11] = "charmingPoop"}
local SLOT, SHOPKEEPER, FIREPLACE = 6, 17, 33

-- Feature key of one layout entry, or nil.
function M.fromLayout(t, variant, subtype)
    if t == SLOT then return M.KINDS["slot" .. variant] and "slot" .. variant or nil end
    if t == SHOPKEEPER then return "shopkeeper" end
    if t == FIREPLACE then return FIRES[variant] end
    if t == 4500 then return variant == 1 and "rewardPlate" or nil end
    return LAYOUT_GRID[t]
end

-- What still stands in the room the players are in: {key = count}.
-- entities: the room's entities; grids are read from room.
function M.scan(room, entities)
    local out = {}
    local function add(key) if key then out[key] = (out[key] or 0) + 1 end end
    for _, e in ipairs(entities) do
        if e.Type == SLOT and not e:IsDead() then
            local animation = e:GetSprite():GetAnimation()
            if animation ~= "Broken" and animation ~= "Death" then add(M.fromLayout(SLOT, e.Variant, e.SubType)) end
        elseif e.Type == SHOPKEEPER and not e:IsDead() then add("shopkeeper")
        elseif e.Type == FIREPLACE and not e:IsDead() and e.HitPoints > 1 then add(FIRES[e.Variant]) end
    end
    local poop = GridEntityType and GridEntityType.GRID_POOP or 14
    local plate = GridEntityType and GridEntityType.GRID_PRESSURE_PLATE or 20
    for index = 0, room:GetGridSize() - 1 do
        local grid = room:GetGridEntity(index)
        if grid then
            local t = grid:GetType()
            -- A poop is gone at State 1000; a pressed plate is at State 3.
            if t == poop and grid.State < 1000 then
                local v = grid:GetVariant()
                if v < 8 or v > 10 then add(POOPS[v]) end -- one giga poop, not its four corners
            elseif t == plate and grid:GetVariant() == 1 and grid.State ~= 3 then add("rewardPlate") end
        end
    end
    return out
end

-- Worth for the floor score, and whether an ordinary room should be listed.
function M.value(features)
    local points, notable = 0, false
    for key, n in pairs(features or {}) do
        local kind = M.KINDS[key]
        if kind and n > 0 then
            points = points + kind[3]*n
            if kind[4] then notable = true end
        end
    end
    return points, notable
end

-- Words {text} in a fixed order: "beggar", "golden poop 2"...
function M.words(features, lang)
    local out = {}
    for _, key in ipairs(M.ORDER) do
        local n = features and features[key]
        if n and n >= 0.5 then
            local kind = M.KINDS[key]
            local name = lang == "zh" and kind[2] or kind[1]
            n = math.floor(n + 0.5)
            out[#out+1] = n > 1 and (name .. " " .. n) or name
        end
    end
    return out
end

return M
