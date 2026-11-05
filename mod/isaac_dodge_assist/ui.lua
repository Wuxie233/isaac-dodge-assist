-- Screen text and shapes in the player's language. The game language
-- (Options.Language: "zh" Simplified Chinese, anything else English) picks
-- the strings, item names (item_names.lua, from the game's own string
-- table) and the font: the game's CJK pixel font for Chinese, an outlined
-- small font for English. Without a font (tests, a missing file) text
-- falls back to Isaac.RenderScaledText. Display only.
local M = {}
local floor = math.floor

-- Font files shipped with the game (native/research/text-and-fonts.md).
-- LanaPixel is what the game itself draws small Chinese HUD text with (13
-- px with its baked shadow, ASCII included); LuaMiniOutlined is ASCII only
-- and outlined, readable over any floor (10 px spacing clears its ink).
M.FONTS = {
    zh = {path = "font/cjk/lanapixel.fnt", scale = 1, line = 13},
    en = {path = "font/luaminioutlined.fnt", scale = 1, line = 10},
}

local STRINGS = {
    en = {
        dodge = "Dodge", dodgeOff = "Dodge off (F6)", paused = "Paused (Shift)", standby = "Dodge",
        pickPlayer = "Press F7 to pick your player", repickPlayer = "Press F7 to pick your player again",
        unsupported = "Character not supported",
        aim = "Auto aim", auto = "Auto combat", preview = "Danger preview",
        floorLine = "Floor %s %d", unseenItems = "%d unknown",
        on = "on", off = "off",
        toastDodge = "Dodge: %s", toastPause = "Paused (Shift again to resume)", toastResume = "Resumed",
        toastWindow = "Prediction window: %d ms", toastPlayer = "Dodging for P%d", toastPreview = "Danger preview: %s",
        toastCombat = "Combat: %s", combatOff = "off",
        toastLoaded = "Dodge Assist v%s loaded", toastReloaded = "Dodge Assist updated to v%s",
        you = "P%d",
        mapTitle = "Floor map", score = "Score %s %d", scoreParts = "items %d + loot %d + rooms %d",
        items = "Items", noItems = "none seen yet", loot = "Loot", rooms = "Rooms", noRooms = "nothing special",
        forecastMark = "~ = forecast, room not entered", unknownItem = "item #%d",
        more = "+%d more",
        deal = "deal", shop = "shop",
        coins = "coins %d", keys = "keys %d", bombs = "bombs %d", hearts = "hearts %d", chests = "chests %d",
        rocks = "reward rocks %d", other = "other %d",
        dealChance = "Devil/Angel %d%%", planetarium = "Planetarium %d%%",
        time = "Time %s", bossRush = "Boss Rush %s", hush = "Hush %s", closed = "closed", left = "%s left",
        forecastExact = "Item forecast: exact", forecastApprox = "Item forecast: approximate (run not followed from its start)",
        forecastOff = "Item forecast: off (%s)", forecastError = "Item forecast: off (error)",
        greed = "Greed mode", challenge = "challenge", chaos = "Chaos", tmtrainer = "TMTRAINER",
        hint = "F5 close",
    },
    zh = {
        dodge = "躲避", dodgeOff = "躲避已关闭（F6）", paused = "已暂停（Shift）", standby = "躲避",
        pickPlayer = "按 F7 选择你的角色", repickPlayer = "按 F7 重新选择角色",
        unsupported = "暂不支持该角色",
        aim = "自动瞄准", auto = "自动战斗", preview = "危险预览",
        floorLine = "本层 %s %d", unseenItems = "未知 %d",
        on = "开", off = "关",
        toastDodge = "躲避：%s", toastPause = "已暂停（再按 Shift 继续）", toastResume = "已继续",
        toastWindow = "预测窗口：%d 毫秒", toastPlayer = "躲避对象：P%d", toastPreview = "危险预览：%s",
        toastCombat = "战斗辅助：%s", combatOff = "关",
        toastLoaded = "躲避助手 v%s 已加载", toastReloaded = "躲避助手已更新到 v%s",
        you = "P%d",
        mapTitle = "本层地图", score = "评分 %s %d", scoreParts = "道具 %d + 资源 %d + 房间 %d",
        items = "道具", noItems = "还没见到", loot = "资源", rooms = "房间", noRooms = "没有特殊房间",
        forecastMark = "~ 为预测，房间还没进", unknownItem = "道具 #%d",
        more = "还有 %d 件",
        deal = "交易", shop = "商店",
        coins = "硬币 %d", keys = "钥匙 %d", bombs = "炸弹 %d", hearts = "心 %d", chests = "箱子 %d",
        rocks = "奖励石头 %d", other = "其他 %d",
        dealChance = "恶魔/天使 %d%%", planetarium = "星象房 %d%%",
        time = "用时 %s", bossRush = "Boss Rush %s", hush = "Hush %s", closed = "已关闭", left = "剩 %s",
        forecastExact = "道具预测：精确", forecastApprox = "道具预测：近似（本局没有从开局跟踪）",
        forecastOff = "道具预测：关闭（%s）", forecastError = "道具预测：关闭（出错）",
        greed = "贪婪模式", challenge = "挑战", chaos = "混沌", tmtrainer = "TMTRAINER",
        hint = "F5 关闭",
    },
}
M.STRINGS = STRINGS

-- Room kinds: map cell label, legend name, short tag before an item.
local ROOMS = {
    en = {
        ROOM_SHOP = {"$", "Shop", "Shop"}, ROOM_TREASURE = {"T", "Treasure", "Treas"}, ROOM_BOSS = {"B", "Boss", "Boss"},
        ROOM_MINIBOSS = {"M", "Miniboss", "Mini"}, ROOM_SECRET = {"S", "Secret", "Secr"},
        ROOM_SUPERSECRET = {"SS", "Super secret", "SSec"}, ROOM_ULTRASECRET = {"U", "Ultra secret", "USec"},
        ROOM_ARCADE = {"A", "Arcade", "Arcd"}, ROOM_CURSE = {"C", "Curse", "Curse"}, ROOM_CHALLENGE = {"!", "Challenge", "Chal"},
        ROOM_LIBRARY = {"L", "Library", "Libr"}, ROOM_SACRIFICE = {"X", "Sacrifice", "Sacr"}, ROOM_DEVIL = {"D", "Devil", "Devil"},
        ROOM_ANGEL = {"A", "Angel", "Angel"}, ROOM_ISAACS = {"Bd", "Bedroom", "Bed"}, ROOM_BARREN = {"Bd", "Bedroom", "Bed"},
        ROOM_CHEST = {"V", "Vault", "Vault"}, ROOM_DICE = {"Di", "Dice", "Dice"}, ROOM_BLACK_MARKET = {"BM", "Black market", "BMkt"},
        ROOM_PLANETARIUM = {"P", "Planetarium", "Plnt"}, ROOM_TELEPORTER = {"Tp", "Teleporter", "Tele"},
        ROOM_TELEPORTER_EXIT = {"Tp", "Teleporter", "Tele"}, ROOM_SECRET_EXIT = {"Ex", "Secret exit", "Exit"},
        ROOM_BOSSRUSH = {"BR", "Boss Rush", "Rush"}, ROOM_ERROR = {"E", "I AM ERROR", "Err"},
    },
    zh = {
        ROOM_SHOP = {"商", "商店", "商店"}, ROOM_TREASURE = {"宝", "宝箱房", "宝箱"}, ROOM_BOSS = {"首", "头目房", "头目"},
        ROOM_MINIBOSS = {"小", "小头目房", "小头目"}, ROOM_SECRET = {"隐", "隐藏房", "隐藏"},
        ROOM_SUPERSECRET = {"超", "超级隐藏房", "超隐"}, ROOM_ULTRASECRET = {"究", "究极隐藏房", "究隐"},
        ROOM_ARCADE = {"赌", "赌场", "赌场"}, ROOM_CURSE = {"诅", "诅咒房", "诅咒"}, ROOM_CHALLENGE = {"挑", "挑战房", "挑战"},
        ROOM_LIBRARY = {"书", "图书馆", "图书"}, ROOM_SACRIFICE = {"献", "献祭房", "献祭"}, ROOM_DEVIL = {"恶", "恶魔房", "恶魔"},
        ROOM_ANGEL = {"天", "天使房", "天使"}, ROOM_ISAACS = {"卧", "卧室", "卧室"}, ROOM_BARREN = {"卧", "卧室", "卧室"},
        ROOM_CHEST = {"库", "宝库", "宝库"}, ROOM_DICE = {"骰", "骰子房", "骰子"}, ROOM_BLACK_MARKET = {"黑", "黑市", "黑市"},
        ROOM_PLANETARIUM = {"星", "星象房", "星象"}, ROOM_TELEPORTER = {"传", "传送房", "传送"},
        ROOM_TELEPORTER_EXIT = {"传", "传送房", "传送"}, ROOM_SECRET_EXIT = {"出", "秘密出口", "出口"},
        ROOM_BOSSRUSH = {"车", "头目车轮战", "车轮"}, ROOM_ERROR = {"错", "错误房", "错误"},
    },
}
M.ROOMS = ROOMS

local lang, langAt, forced = nil, -1000, nil
local loadFont
-- "zh" or "en", re-read every few seconds (the language can change in the
-- options menu without a restart). Chinese needs its font: if the game
-- cannot load it, English is shown rather than unreadable glyphs.
function M.lang()
    if forced then return forced end
    local now = Isaac.GetFrameCount and Isaac.GetFrameCount() or 0
    if not lang or now - langAt > 150 or now < langAt then
        langAt = now
        local ok, value = pcall(function() return Options and Options.Language end)
        lang = (ok and value == "zh" and loadFont("zh") ~= false) and "zh" or "en"
    end
    return lang
end
function M.setLang(value) forced = value end -- tests

function M.t(key, ...)
    local text = STRINGS[M.lang()][key] or STRINGS.en[key] or key
    if select("#", ...) > 0 then return string.format(text, ...) end
    return text
end

local roomTypeNames
-- {cell label, legend name, item tag} of a room type, or nil for an
-- ordinary room.
function M.room(roomType)
    if not roomTypeNames then
        roomTypeNames = {}
        for name, value in pairs(RoomType or {}) do roomTypeNames[value] = name end
    end
    local name = roomTypeNames[roomType]
    return name and ROOMS[M.lang()][name]
end

-- Official item name in the current language, else one spelled from the
-- localisation key, else the id.
local names
function M.itemName(id, fallback)
    if names == nil then
        local ok, table_ = pcall(include, "item_names")
        names = ok and type(table_) == "table" and table_ or false
    end
    local list = names and names[M.lang()]
    return list and list[id] or (names and names.en and names.en[id]) or fallback or M.t("unknownItem", id)
end

-- Fonts load on first use: the Font, false when it failed to load, or
-- nil when the API has no fonts at all (tests: plain fallback text).
local fonts = {}
function loadFont(key)
    if not (Font and KColor) then return nil end
    if fonts[key] == nil then
        fonts[key] = false
        pcall(function()
            local f = Font()
            f:Load(M.FONTS[key].path)
            if f:IsLoaded() then fonts[key] = f end
        end)
    end
    return fonts[key]
end
local function font()
    local key = M.lang()
    return loadFont(key) or nil, M.FONTS[key]
end

function M.lineHeight()
    local _, spec = font()
    return spec.line
end
-- Width in screen pixels.
function M.width(str, scale)
    local f, spec = font()
    scale = (scale or 1) * spec.scale
    if f then return f:GetStringWidthUTF8(str) * scale end
    return #str * 6 * scale
end
-- str cut (by characters, UTF-8 aware) to fit width, with ".." when cut.
function M.fit(str, width, scale)
    if M.width(str, scale) <= width then return str end
    local chars = {}
    for _, code in utf8.codes(str) do chars[#chars+1] = utf8.char(code) end
    for n = #chars - 1, 1, -1 do
        local cut = table.concat(chars, "", 1, n) .. ".."
        if M.width(cut, scale) <= width then return cut end
    end
    return ".."
end
-- Text with its top-left at (x,y); colour {r,g,b}; alpha 0-1.
function M.text(str, x, y, colour, alpha, scale)
    local f, spec = font()
    scale = (scale or 1) * spec.scale
    alpha = alpha or 1
    if f then
        f:DrawStringScaledUTF8(str, floor(x), floor(y), scale, scale, KColor(colour[1], colour[2], colour[3], alpha), 0, false)
    elseif Isaac.RenderScaledText then
        Isaac.RenderScaledText(str, x, y, scale*0.5, scale*0.5, colour[1], colour[2], colour[3], alpha)
    else
        Isaac.RenderText(str, x, y, colour[1], colour[2], colour[3], alpha)
    end
end

-- Filled rectangles from the stretched 4x4 white sprite of the overlay.
local sprite
local function shapes()
    if not sprite then
        sprite = Sprite()
        sprite:Load("gfx/iad/iad_shapes.anm2", true)
        sprite:Play("Line", true)
    end
    return sprite
end
function M.rect(x, y, w, h, colour, alpha)
    if not Sprite then return end
    local s = shapes()
    s.Color = Color(colour[1], colour[2], colour[3], alpha or 1, 0, 0, 0)
    s.Rotation = 0
    s.Scale = Vector(w / 4, h / 4)
    s:Render(Vector(x, y + h/2), Vector(0, 0), Vector(0, 0))
end
function M.frame(x, y, w, h, colour, alpha, t)
    t = t or 1
    M.rect(x, y, w, t, colour, alpha); M.rect(x, y + h - t, w, t, colour, alpha)
    M.rect(x, y, t, h, colour, alpha); M.rect(x + w - t, y, t, h, colour, alpha)
end

-- Item quality colours (0-4) shared by the HUD and the map.
M.QUALITY = {[0] = {0.6, 0.6, 0.62}, {0.9, 0.9, 0.9}, {0.55, 0.8, 1}, {0.85, 0.6, 1}, {1, 0.8, 0.25}}
M.DIM, M.TEXT, M.GOOD, M.WARN, M.MUTED = {0.6, 0.6, 0.65}, {0.92, 0.92, 0.92}, {0.45, 0.95, 0.5}, {1, 0.65, 0.25}, {0.45, 0.45, 0.5}

return M
