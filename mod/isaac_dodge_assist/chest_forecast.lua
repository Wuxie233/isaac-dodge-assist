--[[
chest_forecast.lua - what a chest, sack or alt rock on the floor will give, before it is opened.
The Binding of Isaac: Repentance+ v1.9.7.17.J460, vanilla (no REPENTOGON). Pure Lua 5.3: no game
calls except in M.readContext (pure reads), never an RNG:Next() on a game RNG.

Reconstructed from isaac-ng.exe (native/research/chest-contents.md):
  Entity_Pickup::GetLootList @0x6dae40 (chests, sacks), Entity_Pickup::TryOpenChest @0x6e6e40,
  sack opening in Entity_Pickup collision @0x6e8ae0, Sack Head in pickup update @0x6e41b1,
  GridEntity_Rock::SpawnDrops @0x71b410 (alt rocks), GetAltRockType @0x718ee0.

Chests and sacks ---------------------------------------------------------------------------
  local CF = include("chest_forecast")
  local ctx = CF.readContext(Game(), opener, unlocked)     -- or build the table yourself (below)
  local r = CF.predict(p.Variant, p.SubType, p:GetDropRNG():GetSeed(), ctx, p.InitSeed)

  seed     the chest's DropRNG state: pickup:GetDropRNG():GetSeed() (GetDropRNG returns the live
           RNG at entity+0x3dc, GetSeed only reads it). Entity::Init sets it to RNG(InitSeed, 30),
           so for an unopened chest it equals InitSeed; an eternal chest that closed again has
           moved on, which GetSeed() follows.
  initSeed the chest's InitSeed (only needed for the pedestal a chest turns into: X7(InitSeed)).

  r = { empty = true|nil,                   -- opened with nothing (eternal chest 1 in 4 on reopen)
        groups = { {type=5, variant=20, subtype=2, count=1}, ... },  -- in spawn order, merged
        items  = { {pool=, pickSeed=, pedestalSeed=, excludeDevilSacrifice=bool,
                    cycleSeed=X38(pedestalSeed), probeSeed?}, ... },  -- collectibles
        entries = { {type,variant,subtype,seed,k, pool?,pickSeed?, spawnVariant?, note?,
                     sackHead?}, ... },                               -- raw list
        uncertain = { "poker chip", ... } or nil, rngAfter = DropRNG state after opening }
  Each pickup's subtype is what it becomes when it spawns (M.resolve: coin value, heart kind,
  key, bomb, battery, sack, chest kind), unless ctx.resolve == false. Still 0: pill colour, card,
  trinket; -1: a rune or soul stone. entry.note says when an unknown unlock or an unmodelled rule
  could change it. Other types: 0.1 teleport (red chest), 3.43 / 3.73 blue flies / spiders,
  4.4 mega troll bomb, 18 attack fly (Poker Chip), 85 spider.
  Resolve items with item_emulator, in the current room (room blacklist applies):
    local picks = {}
    for i, it in ipairs(r.items) do picks[i] = {it.pool, it.pickSeed} end
    local ids = emu:predictRoom(picks, opts, true)
  With excludeDevilSacrifice, wrap opts.isAvailable to refuse CF.DEVIL_SACRIFICE ids
  (GetCollectible flag 0x200, Dark Room start-room red chests).
  With probeSeed (Poker Chip held): q = quality of emu:predict(pool, probeSeed, opts); the item is
  emu:predict(pool, pickSeed, opts) with isAvailable also requiring quality == (q > 2 and q or q + 1)
  (data.items[id].q); a result of Breakfast (25) means nothing. Not seen in the logs.
  Tainted Isaac: a chest pedestal's second item is picked from the CURRENT ROOM's pool
  (Emu.poolForRoom(room type)) with seed cycleSeed, right after the first.

  ctx (all optional; missing = none):
    trinkets   = { [TrinketType] = summed GetTrinketMultiplier over players }  -- 22 Daemon's Tail,
                 34 Child's Heart, 36 Rusted Key, 41 Match Stick, 42 Lucky Toe, 44 Safety Cap,
                 45 Ace of Spades, 76 Poker Chip, 159 Gilded Key
    momsKey    = any player has Mom's Key (199)        sackHead = any player has Sack Head (424)
    stage      = level:GetStage()                       greed    = game:IsGreedMode()
    roomIndex  = level:GetCurrentRoomIndex()            startRoomIndex = level:GetStartingRoomIndex()
    leftHand   = the opening player's GetTrinketMultiplier(61)  (red chests)
    redKeyUnlocked = achievement 415 (Red Key): Mom's chest gives a pool item, not the Red Key.
                 Proxy: Isaac.GetItemConfig():GetCollectible(580):IsAvailable() (item 580 has a=415)
    for subtypes (M.resolve): collectibles = {[id]=true} (173 Mitre, 203 Humbling Bundle, 238/239
                 Key Pieces, 250 Bogo Bombs, 251 Starter Deck, 252 Little Baggy), trinkets also
                 17, 18, 38, 61, 87, 151, 165, playerTypes = {[PlayerType]=true} (5 Eve, 16/17
                 Forgotten), hard = Difficulty 1 or 3, roomType = room:GetType(),
                 unlocked = set or fn of achievement ids (M.UNLOCK_IDS; nil = unknown, treated as
                 locked and named in entry.note), allTaintedBlueBaby (bombs -> poops)
  Any held trinket from the list shifts the RNG, so a wrong trinket set gives a wrong answer.
  Player::HasTrinket also answers for the trinket the Error trinket (75) imitates.

Alt rocks ------------------------------------------------------------------------------------
  local r = CF.rock(g:GetType(), room:GetBackdropType(), g:GetSaveState().SpawnSeed, rctx)
  g:GetSaveState() returns the live GridEntityDesc; SpawnSeed is what SpawnDrops rolls on.
  rctx = { isRemoved = fn(collectibleId) -> bool (item_emulator: emu:isRemoved),
           trinketAvailable = fn(trinketId) -> bool (not in vanilla Lua: IsAvailable and
           "not spawned yet this run" is the best guess), luckyRock = multiplier of trinket 15,
           roomType = room:GetType() (secret room 7: Wavy Cap roll), plus the M.resolve fields
           (unlocked, hard, trinkets, ...) for the subtype of chain-seeded drops }
  r = { kind = 1 urn | 2 mushroom | 3 skull | 4 polyp | 5 bucket | "marked skull",
        item = collectible id | nil, trinket = trinket id | nil,
        groups = { {type=5, variant=, subtype=, count=} }, bad = "spiders"|"gas"|"host"|"creep"|
        "bucket" | nil, nothing = bool, uncertain = {...} | nil,
        entries = { {type, variant, subtype, seed, k} } }  -- pickups seeded from the rock's chain
  The good roll's pickups (pill, card, heart, coins) take chain seeds, so their InitSeed is known;
  the rare item, trinket and black heart take Random() seeds.
]]

local M = {}

local M32 = 0xFFFFFFFF
local SHIFT = {
  [1] = {1, 5, 16}, [2] = {1, 5, 19}, [3] = {1, 9, 29}, [4] = {1, 11, 6}, [5] = {1, 11, 16},
  [6] = {1, 19, 3}, [7] = {1, 21, 20}, [30] = {4, 3, 17}, [35] = {5, 9, 7}, [38] = {5, 13, 6},
}
local function X(x, idx)
  local s = SHIFT[idx]
  x = x & M32
  x = x ~ (x >> s[1])
  x = x ~ ((x << s[2]) & M32)
  x = x ~ (x >> s[3])
  return x & M32
end
M.next = X

-- the game's RNG object: state + shift index; k counts Next() calls
local function newRng(seed, idx) return { s = seed & M32, idx = idx, k = 0 } end
local function nxt(r) r.s = X(r.s, r.idx); r.k = r.k + 1; return r.s end
local function rint(r, n) local v = nxt(r); if n == 0 then return 0 end return v % n end

-- WeightedOutcomePicker @0x49cbf0: roll = X35(r) % total; first entry whose running sum > roll
local function pick(tab, r)
  local total = 0
  for i = 1, #tab do total = total + tab[i][2] end
  local roll = total > 0 and X(r, 35) % total or 0
  local acc = 0
  for i = 1, #tab do
    acc = acc + tab[i][2]
    if roll < acc then return tab[i][1] end
  end
  return 0
end

M.VARIANT = { CHEST = 50, BOMB_CHEST = 51, SPIKED = 52, ETERNAL = 53, MIMIC = 54, OLD = 55, WOODEN = 56,
  MEGA = 57, HAUNTED = 58, GOLDEN = 60, RED = 360, MOMS = 390, SACK = 69 }
local CONTAINER = { [50] = true, [51] = true, [52] = true, [53] = true, [54] = true, [55] = true, [56] = true,
  [57] = true, [58] = true, [60] = true, [360] = true, [390] = true, [69] = true }
function M.isContainer(variant) return CONTAINER[variant] == true end

local DAEMON, CHILD, RUSTED, MATCH, LUCKY_TOE, SAFETY, ACE, POKER, GILDED = 22, 34, 36, 41, 42, 44, 45, 76, 159
-- tag "devilsacrifice" (items_metadata.xml): refused by GetCollectible flag 0x200
M.DEVIL_SACRIFICE = { [126] = true, [157] = true, [186] = true, [225] = true, [569] = true, [672] = true,
  [692] = true, [695] = true, [704] = true }

--- Seed of the pedestal a chest turns into (Entity_Pickup::Morph without KeepSeed: X7(InitSeed)).
function M.pedestalInitSeed(initSeed) return X(initSeed, 7) end
--- Tainted Isaac: seed of a pedestal's second item (picked from the room's pool).
function M.cycleSeed(pedestalSeed) return X(pedestalSeed, 38) end

--- Raw loot list: Entity_Pickup::GetLootList(advance=true) for one opening.
--- Returns entries, rng (rng.s = DropRNG state afterwards; rng.k = Next() calls made).
function M.loot(variant, subtype, seed, ctx)
  ctx = ctx or {}
  local tr = ctx.trinkets or {}
  local function has(t) return (tr[t] or 0) > 0 end
  local rng = newRng(seed, 30)
  local copies = { [DAEMON] = newRng(seed, 1), [ACE] = newRng(seed, 2), [SAFETY] = newRng(seed, 3),
    [MATCH] = newRng(seed, 4), [CHILD] = newRng(seed, 5), [RUSTED] = newRng(seed, 6) }
  local out = {}
  local function push(t, v, s, sd, k, pool, pickSeed)
    out[#out + 1] = { type = t, variant = v, subtype = s, seed = sd, k = k, pool = pool, pickSeed = pickSeed }
  end
  local function simple(t, v, s) local sd = nxt(rng); push(t, v, s or 0, sd, rng.k) end
  local function item(pool, flag)
    local sd = nxt(rng); local k = rng.k
    local p = nxt(rng)
    push(5, 100, 0, sd, k, pool, p)
    if flag then out[#out].excludeDevilSacrifice = true end
  end
  -- Poker Chip item (@0x6ee640): probe = GetCollectible(pool, probeSeed, no decrease) gives quality q;
  -- the item is GetCollectible(pool, pickSeed) restricted to quality q+1 (q if q > 2)
  local function pokerItem(pool, backup)
    local sd = nxt(rng); local k = rng.k
    local probe = nxt(rng)
    local p = nxt(rng)
    push(5, 100, 0, sd, k, pool, p)
    out[#out].probeSeed = probe
    out[#out].backupPool = backup
  end
  local stage = ctx.stage or 1

  -- eternal chest: reopened (subtype < 2) outside stage 11, 1 in 4 is empty
  if variant == 53 and stage ~= 11 and subtype < 2 then
    if nxt(rng) & 3 == 0 then return out, rng end
  end
  -- pickup trinkets roll first (one roll each, only when held)
  local daemon = has(DAEMON)
  local flags = {}
  for _, t in ipairs({ ACE, SAFETY, CHILD, MATCH, RUSTED }) do
    if has(t) then
      local skip = false
      if t == CHILD and daemon and nxt(rng) % 5 ~= 0 then skip = true end
      if not skip then
        local mult = tr[t]
        local chance = mult == 2 and 66 or (mult >= 3 and 100 or 33)
        if nxt(rng) % 100 < chance then flags[t] = true end
      end
    end
  end
  local cb = (not ctx.greed) and stage == 11
  local poker = has(POKER)
  local coin = poker and (X(rng.s, 7) & 1) == 0
  local luckyToe = has(LUCKY_TOE)
  local momsKey = ctx.momsKey
  local uncertain
  local function note(s) uncertain = uncertain or {}; uncertain[#uncertain + 1] = s end
  if poker then note("poker chip") end

  local function bonus(list)
    for _, e in ipairs(list) do
      if flags[e[1]] then
        local c = copies[e[1]]
        local sd = nxt(c)
        push(5, e[2], 0, sd, nil)
        return
      end
    end
  end

  if variant == 56 then -- wooden chest
    local tab = { {0, 2}, {1, 10}, {2, 10} }
    local o1 = pick(tab, nxt(rng))
    local n = (nxt(rng) & 1) + 2
    if o1 ~= 0 and nxt(rng) % 3 ~= 0 and luckyToe then n = n + 1 end
    bonus({ {ACE, 300}, {SAFETY, 70} })
    if momsKey then n = n * 2 end
    if poker then
      if not coin then simple(18, 0); return out, rng, uncertain end
      n = n * 2
    end
    if n == 0 then simple(18, 0); return out, rng, uncertain end
    local o2 = pick(tab, nxt(rng))
    if o2 == 0 then
      if poker then pokerItem(29, 0) else item(29) end
    elseif o2 == 1 then for _ = 1, n do simple(5, 300) end
    else for _ = 1, n do simple(5, 70) end end
    return out, rng, uncertain
  end

  if variant == 360 then -- red chest
    if cb and ctx.roomIndex ~= nil and ctx.roomIndex == ctx.startRoomIndex then
      item(3, true); return out, rng, uncertain
    end
    local room = ctx.roomIndex or 0
    local tab = { {0, 10} }
    if room ~= -1 and room ~= -12 then tab[#tab + 1] = {1, 5} end
    if (ctx.leftHand or 0) < 3 then tab[#tab + 1] = {2, 13} end
    tab[#tab + 1] = {3, 13}; tab[#tab + 1] = {4, 7}; tab[#tab + 1] = {5, 7}
    tab[#tab + 1] = {6, daemon and 3 or 15}; tab[#tab + 1] = {7, 15}; tab[#tab + 1] = {8, 15}
    local o = pick(tab, nxt(rng))
    if o == 0 then item(9)
    elseif o == 1 then push(0, 1, 0, 0, nil)          -- teleports the player to the devil room
    elseif o == 2 then simple(85, 0); simple(85, 0)   -- two spiders
    elseif o == 3 then simple(4, 4)                    -- mega troll bomb
    elseif o == 4 then for _ = 1, 3 do simple(3, 43) end   -- blue flies
    elseif o == 5 then for _ = 1, 3 do simple(3, 73) end   -- blue spiders
    elseif o == 6 then
      simple(5, 10, 3)
      if rint(rng, 2) == 0 and ((not daemon) or rint(copies[DAEMON], 5) == 0) then simple(5, 10, 3) end
    elseif o == 7 then simple(5, 40, 3); simple(5, 40, 3)   -- troll bombs
    else simple(5, 70); simple(5, 70) end
    if (ctx.leftHand or 0) > 1 then
      local r = nxt(rng)
      simple(5, r & 1 == 0 and 70 or 10, 3)
    end
    return out, rng, uncertain
  end

  if variant == 390 then
    -- Mom's chest: Red Key (580) until achievement 415 (PersistentGameData byte 76 + 415), then an
    -- item from the Mom's chest pool (15). The game also takes a second, unidentified unlock state
    -- there (save mode 2 plus a game flag)
    if ctx.redKeyUnlocked then item(15) else simple(5, 100, 580) end
    if ctx.redKeyUnlocked == nil then note("mom's chest: red key or item") end
    return out, rng, uncertain
  end

  if variant == 55 then -- old chest
    local tab = { {0, daemon and 9 or 43}, {1, 42}, {2, 10}, {3, 5} }
    local o = pick(tab, nxt(rng))
    if o == 0 then for _ = 1, rint(rng, 3) + 1 do simple(5, 10, 3) end
    elseif o == 1 then for _ = 1, 3 do simple(5, 350) end
    elseif o == 2 then item(27)
    else item(4) end
    return out, rng, uncertain
  end

  if variant == 69 then -- sack (subtype 2: black sack)
    local tab = { {40, 15} }
    if subtype == 2 then
      tab[2] = {0x6000a, 10}; tab[3] = {0xb000a, 5}; tab[4] = {70, 15}
    else
      tab[2] = {30, 20}; tab[3] = {20, 15}; tab[4] = {90, 4}; tab[5] = {300, 4}
    end
    for _ = 1, rint(rng, 2) + 2 do
      local o = pick(tab, nxt(rng))
      nxt(rng)
      simple(5, o & 0xffff, o >> 16)
      if subtype == 2 and o & 0xffff == 10 then
        for _, e in ipairs(tab) do
          if e[1] == 0x6000a then e[2] = math.max(0, e[2] - 10) end
          if e[1] == 0xb000a then e[2] = math.max(0, e[2] - 5) end
        end
      end
    end
    return out, rng, uncertain
  end

  -- 50 brown, 51 stone, 52 spiked, 53 eternal, 54 mimic, 57 mega, 58 haunted, 60 golden
  local c1 = variant == 60 or variant == 51 or variant == 53 or variant == 57
  local mega = variant == 57
  if cb or (mega and rint(rng, 2) == 0) then   -- stage 11 (Dark Room/Chest): treasure items
    item(0)
    if mega then item(0) end
    return out, rng, uncertain
  end
  local tab
  if c1 and has(GILDED) then
    tab = { {7, 80} }
    if not mega then tab[2] = {6, 20} end
  else
    tab = { {0, 10} }
    if not mega then tab[#tab + 1] = {1, 1}; tab[#tab + 1] = {2, 1} end
    if c1 then
      tab[#tab + 1] = {5, 10}
      if not mega then tab[#tab + 1] = {6, 20} end
      tab[#tab + 1] = {3, 58}
    else
      tab[#tab + 1] = {4, 10}; tab[#tab + 1] = {3, 78}
    end
  end
  local heartW = daemon and 4 or 20
  for _ = 1, mega and 5 or 1 do
    local o = pick(tab, nxt(rng))
    if o == 0 then simple(5, 350)
    elseif o == 1 then simple(5, 50)
    elseif o == 2 then simple(5, 60)
    elseif o == 3 or o == 7 then
      local n = math.max(2, rint(rng, c1 and 7 or 4))
      bonus({ {ACE, 300}, {SAFETY, 70}, {MATCH, 40}, {CHILD, 10}, {RUSTED, 30} })
      if rint(rng, 3) ~= 0 and luckyToe then n = n + 1 end
      if momsKey then n = n * 2 end
      if poker then
        n = n * 2
        if not coin then n = 0 end
        if n == 0 then simple(18, 0) end
      end
      local inner
      if o == 7 then
        inner = { {0, 25}, {1, heartW}, {2, 10}, {3, 20}, {4, 5}, {5, 5}, {6, 5}, {7, 5}, {8, 5} }
      else
        inner = { {0, 35}, {1, heartW}, {2, 15}, {3, 30} }
      end
      for _ = 1, n do
        local o2 = pick(inner, nxt(rng))
        if o2 == 0 then for _ = 1, rint(rng, 3) + 1 do simple(5, 20) end
        elseif o2 == 1 then simple(5, 10)
        elseif o2 == 2 then simple(5, 30)
        elseif o2 == 3 then simple(5, 40)
        elseif o2 == 4 then simple(5, 70)
        elseif o2 == 5 then simple(5, 300)
        elseif o2 == 6 then simple(5, 300, -1); out[#out].cardSeed = nxt(rng)   -- rune: GetCard(cardSeed, runes)
        elseif o2 == 7 then simple(5, 350)
        else simple(5, 90) end
      end
    elseif o == 4 then simple(5, 70)
    elseif o == 5 then simple(5, 300)
    else -- 6: collectible from the golden chest pool
      if poker then pokerItem(8, variant == 53 and 4 or 0) else item(8) end
    end
  end
  return out, rng, uncertain
end

--- Sack Head (424): a spawned key/bomb/coin/battery/card (price 0, not from a sack) rolls its own
--- DropRNG(seed, 30): RandomInt(10 coin / 5 other) == 0 -> it is replaced by a sack seeded Next().
function M.applySackHead(entries, spawnerVariant)
  if spawnerVariant == 69 then return entries end
  local out = {}
  for _, e in ipairs(entries) do
    local v = e.variant
    if e.type == 5 and (v == 30 or v == 40 or v == 20 or v == 90 or v == 300) and e.seed then
      local r = newRng(e.seed, 30)
      if rint(r, v == 20 and 10 or 5) == 0 then
        out[#out + 1] = { type = 5, variant = 69, subtype = 0, seed = nxt(r), k = e.k and e.k + 2, sackHead = true,
          replaces = v, replacedK = e.k }
      else
        out[#out + 1] = e
      end
    else
      out[#out + 1] = e
    end
  end
  return out
end

-------------------------------------------------------------------------------
-- What a subtype-0 pickup becomes when it spawns (Entity_Pickup::Init -> @0x6ddcd0, RNG(InitSeed, 35))
-------------------------------------------------------------------------------

-- PersistentGameData byte 76 + id is the unlock flag the selector reads
local function unlockedFn(ctx, notes)
  local u = ctx.unlocked
  return function(a)
    if type(u) == "function" then return u(a) == true end
    if type(u) == "table" then return u[a] == true end
    notes[#notes + 1] = a      -- unknown: treated as locked, reported
    return false
  end
end

--- Resolve one pickup spawned as (variant, 0) with InitSeed seed. Returns variant, subtype, note.
--- Covers hearts, coins, keys, bombs, batteries, sacks and the chest re-roll; pills, cards,
--- trinkets and runes keep subtype 0 (note "not modelled"). ctx: see M.readContext; unlocked =
--- set/function of achievement ids (nil: unknown, treated as locked and listed in note).
function M.resolve(variant, seed, ctx)
  ctx = ctx or {}
  local tr = ctx.trinkets or {}
  local co = ctx.collectibles or {}
  local types = ctx.playerTypes or {}
  local function has(t) return (tr[t] or 0) > 0 end
  local function mult(t) return math.max(1, tr[t] or 0) end
  local notes = {}
  local U = unlockedFn(ctx, notes)
  local r = newRng(seed, 35)
  local v, s = variant, 0
  local sd, lb = co[251], co[252]                 -- Starter Deck / Little Baggy (not both)
  if sd and lb then sd, lb = false, false end
  if v == 70 and sd then v = 300 elseif v == 300 and lb then v = 70 end
  local function done(note)
    if #notes > 0 then note = (note and note .. ", " or "") .. "unlock " .. table.concat(notes, "/") .. " unknown" end
    return v, s, note
  end
  if v == 10 then
    s = 1
    if rint(r, 2) == 0 then s = 2 end
    if rint(r, ctx.hard and 50 or 20) == 0 then s = 5 end
    if rint(r, 50) == 0 and U(411) then s = 12 end
    if rint(r, 100) == 0 and U(328) then s = 9 end
    if rint(r, 100) == 0 then s = 10 end
    local eternal = rint(r, 50) == 0
    if not eternal and has(18) then eternal = rint(r, 30 // mult(18)) == 0 end
    if not eternal and co[238] and rint(r, 40) == 0 then eternal = true end
    if not eternal and co[239] and rint(r, 40) == 0 then eternal = true end
    if eternal then s = 4 end
    local soul = rint(r, 10) == 0
    if not soul and co[173] then soul = rint(r, 3) == 0 end
    if not soul and has(38) then soul = rint(r, 10 // mult(38)) == 0 end
    if not soul and types[5] then soul = rint(r, 16) == 0 end
    if soul then
      s = 3
      if rint(r, 4) == 0 and U(33) then s = 8 end
      if rint(r, 20) == 0 and U(391) then s = 11 end
      local black = rint(r, 20) == 0
      if not black and has(17) then black = rint(r, 10 // mult(17)) == 0 end
      if black then s = 6 end
      if rint(r, 5) == 0 and (types[16] or types[17]) then s = 11 end
    end
    if rint(r, 160) == 0 and U(224) then s = 7 end
    if has(22) and ctx.roomType ~= 8 then s = 6 end
    if ctx.roomType == 8 then return done("super secret room heart") end
    if s == 2 and has(87) then s = 1 end
  elseif v == 20 then
    s = 1
    if rint(r, 20) == 0 then s = 2
    elseif rint(r, 100) == 0 and U(240) then s = 6 end
    if rint(r, 100) == 0 then s = 3
    elseif s == 1 and rint(r, 100) == 0 and U(242) then s = 5 end
    if rint(r, 200) == 0 and U(613) then s = 7 end
  elseif v == 30 then
    s = pick({ {1, 49}, {2, 1}, {U(333) and 4 or 1, 1} }, nxt(r))
  elseif v == 40 then
    s = 1
    if rint(r, 7) == 0 then s = 2 end
    if rint(r, 100) == 0 and U(226) then s = 4 end
    if rint(r, 50) == 0 then s = s == 4 and 6 or 5 end
    if rint(r, 10) == 0 then s = s == 4 and 6 or 3 end
  elseif v == 90 then
    s = 1
    local a, b = nxt(r), nxt(r)
    if (U(33) and a % 3 ~= 0) or (ctx.hard and b & 1 == 1) then s = 2 end
    if rint(r, 100) == 0 then s = 3
    elseif rint(r, 120) == 0 and U(615) then s = 4 end
  elseif v == 69 then
    s = 1
    if rint(r, 100) == 0 and U(604) then s = 2 end
    return done()
  elseif v == 50 or v == 60 then
    if v == 50 then
      if rint(r, 40) == 0 then v = 54
      elseif rint(r, 20) == 0 then v = 360
      elseif rint(r, 50) == 0 then v = 51
      elseif rint(r, 80) == 0 then v = 52
      elseif rint(r, 100) == 0 then
        v, s = 69, 1
        if rint(r, 100) == 0 and U(604) then s = 2 end
        return done()
      else
        if rint(r, 80) == 0 and U(609) then v = 56
        elseif rint(r, 40) == 0 and U(611) then v = 58 end   -- also a level check (@0x42a270), not modelled
      end
    end
    if rint(r, 1600) == 0 then v = 53 end
    if v ~= 360 and has(61) then v = 360 end
    if v == 52 and has(151) then v = 54 end
    if has(159) and not has(61) then v = 60 end
    if v == 60 and rint(r, 120) == 0 and U(601) then v = 57 end
    if v == 57 then s = rint(r, 4) + rint(r, 4) + 1; return done("mega chest lock count unverified") end
    s = v == 53 and 2 or 1
    return done()
  else
    return done("not modelled")
  end
  -- Humbling Bundle (203, when InitSeed bit 15 is clear) / Bogo Bombs (250, bombs): doubles
  if (co[203] and seed & 0x8000 == 0) or (v == 40 and co[250]) then
    if v == 10 and (s == 1 or s == 9) then s = 5 end
    if v == 20 and s == 1 then s = 4 end
    if v == 30 and s == 1 then s = 3 end
    if v == 40 and s == 1 then s = 2 end
  end
  if v == 40 and ctx.allTaintedBlueBaby and s ~= 3 and s ~= 5 and s ~= 6 then v, s = 42, 1 end
  if (v == 20 or v == 30) and has(165) and (ctx.stage or 1) > 6 and not ctx.greed then
    return done("trinket 165 re-roll not modelled")
  end
  return done()
end

--- Summary of one opening: groups, collectible picks (see header).
function M.predict(variant, subtype, seed, ctx, initSeed)
  if not CONTAINER[variant] then return nil end
  if variant ~= 69 and subtype == 0 then return nil end   -- already opened
  ctx = ctx or {}
  local entries, rng, uncertain = M.loot(variant, subtype, seed, ctx)
  -- spawn: subtype-0 pickups take their subtype (Init), then Sack Head checks them (first Update)
  if ctx.resolve ~= false then
    for _, e in ipairs(entries) do
      if e.type == 5 and e.subtype == 0 and e.variant ~= 100 and e.seed then
        local v, s, note = M.resolve(e.variant, e.seed, ctx)
        e.spawnVariant, e.variant, e.subtype, e.note = e.variant, v, s, note
      end
    end
  end
  if ctx.sackHead then
    entries = M.applySackHead(entries, variant)
    if ctx.resolve ~= false then
      for _, e in ipairs(entries) do
        if e.sackHead then e.variant, e.subtype, e.note = M.resolve(69, e.seed, ctx) end
      end
    end
  end
  local r = { entries = entries, groups = {}, items = {}, uncertain = uncertain, rngAfter = rng.s }
  if #entries == 0 then r.empty = true return r end
  local index = {}
  local firstItem = true
  for _, e in ipairs(entries) do
    if e.type == 5 and e.variant == 100 and e.subtype == 0 then
      local ped = firstItem and M.pedestalInitSeed(initSeed or seed) or e.seed
      firstItem = false
      r.items[#r.items + 1] = { pool = e.pool, pickSeed = e.pickSeed, pedestalSeed = ped,
        excludeDevilSacrifice = e.excludeDevilSacrifice or false, cycleSeed = M.cycleSeed(ped),
        probeSeed = e.probeSeed }
    else
      local key = e.type .. "." .. e.variant .. "." .. e.subtype
      local g = index[key]
      if g then g.count = g.count + 1
      else
        g = { type = e.type, variant = e.variant, subtype = e.subtype, count = 1 }
        index[key] = g
        r.groups[#r.groups + 1] = g
      end
    end
  end
  return r
end

-------------------------------------------------------------------------------
-- Alt rocks
-------------------------------------------------------------------------------

local ALT_KIND = {}
for _, b in ipairs({4, 5, 6, 0x17, 0x20, 0x25, 0x2e, 0x3a, 0x3b}) do ALT_KIND[b] = 2 end
for _, b in ipairs({7, 8, 9, 0xe, 0x10, 0x1e, 0x21, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2f}) do ALT_KIND[b] = 3 end
for _, b in ipairs({10, 0xb, 0xc, 0xd, 0x22, 0x2b, 0x2c, 0x30}) do ALT_KIND[b] = 4 end
for _, b in ipairs({0x1f, 0x24, 0x2d}) do ALT_KIND[b] = 5 end
local CORPSE = { [0x22] = true, [0x2b] = true, [0x2c] = true, [0x30] = true }
local DROSS = 0x2d
M.ALT_ROCK = { URN = 1, MUSHROOM = 2, SKULL = 3, POLYP = 4, BUCKET = 5 }

--- GridEntity_Rock::GetAltRockType @0x718ee0: BackdropType -> alt rock kind.
function M.altRockKind(backdrop) return ALT_KIND[backdrop] or 1 end

--- Drops of a GRID_ROCK_ALT (6) or GRID_ROCK_ALT2 (26) when destroyed (one pass).
function M.rock(gridType, backdrop, spawnSeed, rctx)
  rctx = rctx or {}
  local out = { groups = {}, entries = {} }
  local function add(v, s, n)
    out.groups[#out.groups + 1] = { type = 5, variant = v, subtype = s, count = n or 1 }
  end
  local function chained(c, v, s)       -- a pickup spawned with the next chain value as its seed
    local sd = nxt(c)
    out.entries[#out.entries + 1] = { type = 5, variant = v, subtype = s, seed = sd, k = c.k }
  end
  if gridType == 26 then                   -- marked skull: The Fool (a pill with Little Baggy)
    out.kind = "marked skull"
    add(300, 1)
    return out
  end
  if gridType ~= 6 then return nil end
  local kind = M.altRockKind(backdrop)
  local corpse = CORPSE[backdrop]
  out.kind = kind
  local removed = rctx.isRemoved or function() return false end
  local tok = rctx.trinketAvailable or function() return true end
  local c = newRng(spawnSeed, 35)
  local lucky = math.min(rctx.luckyRock or 0, 16)
  for _ = 1, lucky do                     -- Lucky Rock: a penny for each hit (1 in 3)
    if nxt(c) % 3 == 0 then nxt(c); add(20, 1) end
  end
  if lucky > 0 then out.uncertain = { "lucky rock" } end
  local function itemIf(id) if not removed(id) then out.item = id return true end return false end
  -- 1 in 200: a fixed collectible, if it is still in the pools
  if nxt(c) % 200 == 0 then
    if kind == 1 then if itemIf(74) then return out end
    elseif kind == 2 then
      if rctx.roomType == 7 and nxt(c) % 100 == 0 and itemIf(582) then return out end   -- secret room: Wavy Cap
      if (nxt(c) & 1) == 0 and itemIf(71) then return out end
      if itemIf(12) then return out end
    elseif kind == 3 then
      if (nxt(c) & 1) == 0 and itemIf(265) then return out end
      if itemIf(163) then return out end
    elseif kind == 4 then
      local a, b = 218, 254
      if corpse then a, b = 26, 268 end
      if (nxt(c) & 1) == 0 and itemIf(a) then return out end
      if itemIf(b) then return out end
    else
      if itemIf(backdrop == DROSS and 36 or 270) then return out end
    end
  end
  -- 1 in 40: a trinket from the trinket pool (skull: a black heart)
  if nxt(c) % 40 == 0 then
    if kind == 3 then add(10, 6); return out end
    local t = ({ [1] = backdrop == DROSS and 24 or 1, [5] = backdrop == DROSS and 24 or 1, [2] = 32,
      [4] = corpse and 86 or 33 })[kind]
    if tok(t) then out.trinket = t; return out end
  end
  local r = rint(c, 10)
  if r == 1 or r == 3 then
    out.bad = ({ "spiders", "gas", "host", "creep", "bucket" })[kind]
  elseif r == 2 then
    if kind == 2 then chained(c, 70, 0)
    elseif kind == 3 then chained(c, 300, 0)
    elseif kind == 4 then
      if not corpse then chained(c, 10, 0)
      else
        local notes = {}
        if unlockedFn(rctx, notes)(411) then chained(c, 10, 12)          -- rotten heart (achievement 411)
        elseif #notes > 0 then out.uncertain = { "rotten heart unlock unknown" } end
      end
    else
      for _ = 1, rint(c, 2) + 1 do chained(c, 20, 0) end
    end
    -- these spawn with chain seeds: their subtype is known (M.resolve)
    for _, e in ipairs(out.entries) do
      local v, s = e.variant, e.subtype
      if s == 0 and rctx.resolve ~= false then v, s, e.note = M.resolve(v, e.seed, rctx) end
      e.variant, e.subtype = v, s
      local merged = false
      for _, g in ipairs(out.groups) do
        if g.variant == v and g.subtype == s then g.count = g.count + 1; merged = true end
      end
      if not merged then add(v, s) end
    end
  end
  if #out.groups == 0 and not out.bad then out.nothing = true end
  return out
end

-------------------------------------------------------------------------------
-- Context from the game (pure reads only)
-------------------------------------------------------------------------------

-- trinkets and collectibles the loot list or the subtype selection reads
local CTX_TRINKETS = { DAEMON, CHILD, RUSTED, MATCH, LUCKY_TOE, SAFETY, ACE, POKER, GILDED,
  17, 18, 38, 61, 87, 151, 165 }
local CTX_COLLECTIBLES = { 173, 199, 203, 238, 239, 250, 251, 252, 424 }
--- Achievements the subtype selection checks (vanilla Lua cannot read them: pass ctx.unlocked).
--- 33 Everything is Terrible, 224 gold heart, 226 gold bomb, 240 sticky nickel, 242 lucky penny,
--- 328 half soul heart, 333 charged key, 391 bone heart, 411 rotten heart, 415 Red Key,
--- 601 mega chest, 604 black sack, 609 wooden chest, 611 haunted chest, 613 golden penny,
--- 615 golden battery. A gated subtype seen in the run proves its unlock.
M.UNLOCK_IDS = { 33, 224, 226, 240, 242, 328, 333, 391, 411, 415, 601, 604, 609, 611, 613, 615 }
M.UNLOCK_BY_PICKUP = { ["10.7"] = 224, ["40.4"] = 226, ["20.6"] = 240, ["20.5"] = 242, ["10.9"] = 328,
  ["30.4"] = 333, ["10.11"] = 391, ["10.12"] = 411, ["57"] = 601, ["69.2"] = 604, ["56"] = 609,
  ["58"] = 611, ["20.7"] = 613, ["90.4"] = 615 }

--- Context from the game (pure reads only). opener: the player who opens the chest (Left Hand on
--- red chests); may be nil. unlocked: the caller's set of achievement ids (see M.UNLOCK_IDS).
function M.readContext(game, opener, unlocked)
  local level = game:GetLevel()
  local ctx = { trinkets = {}, collectibles = {}, playerTypes = {}, stage = level:GetStage(),
    greed = game:IsGreedMode(), roomIndex = level:GetCurrentRoomIndex(),
    startRoomIndex = level:GetStartingRoomIndex(), roomType = game:GetRoom():GetType(),
    hard = game.Difficulty == 1 or game.Difficulty == 3, unlocked = unlocked }
  for i = 0, game:GetNumPlayers() - 1 do
    local p = Isaac.GetPlayer(i)
    if p and p.Variant == 0 then
      ctx.playerTypes[p:GetPlayerType()] = true
      for _, t in ipairs(CTX_TRINKETS) do
        if p:HasTrinket(t) then
          ctx.trinkets[t] = (ctx.trinkets[t] or 0) + math.max(1, p:GetTrinketMultiplier(t))
        end
      end
      for _, id in ipairs(CTX_COLLECTIBLES) do
        if p:HasCollectible(id) then ctx.collectibles[id] = true end
      end
    end
  end
  ctx.momsKey = ctx.collectibles[199] == true
  ctx.sackHead = ctx.collectibles[424] == true
  if opener then ctx.leftHand = opener:GetTrinketMultiplier(61) end
  return ctx
end

return M
