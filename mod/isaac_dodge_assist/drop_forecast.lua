--[[
drop_forecast.lua - what breaking or using a room feature gives, before anyone acts: poops,
fireplaces, shopkeepers, reward plates, slot machines and beggars, in the room the players are in
or in a room not entered yet. The Binding of Isaac: Repentance+ v1.9.7.17.J460, vanilla (no REPENTOGON). Pure Lua
5.3: no game calls except in M.readContext (pure reads), never an RNG:Next() on a game RNG.

Reconstructed from isaac-ng.exe (native/research/room-feature-drops.md):
  GridEntity_Poop::Hurt @0x715330, SpawnDrops @0x7178c0 (destroyed poop), per-hit drops @0x716db0
  (giga poop chunks, Dirty Mind); fireplace AI @0x6d18d0, drop list @0x6d1580; shopkeeper AI
  @0x6c2220, drop list @0x6c1ac0; GridEntity_PressurePlate update @0x9833c0, trigger @0x984550;
  Entity_Slot payment @0x6627e0, payouts in Update @0x65d950, pickup spawns @0x6657a0, explosion
  drops @0x663aa0. Per-player RNG choice @0x9be3e0 (trinkets) / @0x9be140 (collectibles).

  local DF = include("drop_forecast")      -- includes chest_forecast (pickup subtypes, nested chests)
  local ctx = DF.readContext(Game())        -- or build the table yourself (below)

Poops (grid type 14) --------------------------------------------------------------------------
  local r = DF.poop(g:GetVariant(), g:GetSaveState().SpawnSeed, ctx, g:GetSaveState().VarData)
  variant  0 normal, 1 red, 2 corny, 3 golden, 4 rainbow, 5 black, 6 white, 7-10 giga poop parts,
           11 charming. State 1000 = already destroyed (nothing left to forecast).
  seed     the grid's SpawnSeed (GetSaveState() returns the live GridEntityDesc). It never changes,
           so the forecast holds however many hits it takes: hits only change the damage, which
           the game rolls on the global Random(); the drop is rolled once, at State 1000.
  varData  1 = a poop a player made (The Poop, Tainted ???): drop chance 1 % instead of 10 %.
  Giga poop: its 50 damage chunks each roll a drop as they break; use
  DF.gigaPoop(seedOfPart9, state, ctx) with the SpawnSeed and State of the variant-9 part (the
  other three parts pass their damage to it). It returns the chunks still to come.

Fireplaces (entity 33) ------------------------------------------------------------------------
  local r = DF.fireplace(npc.Variant, npc:GetDropRNG():GetSeed(), ctx, noReward)
  seed     the fireplace's DropRNG state = RNG(InitSeed, 30), untouched until the fire goes out.
  noReward npc:HasEntityFlags(1 << 42): entity flag bit 42 (entity+0x16c & 0x400) empties the drop
           list; the game sets it e.g. on some purple fireplaces at room load (@0x7f4a55). Name unverified.
  Variants 4 (white), 10, 12, 13 (movable) and 11 (coal) drop nothing. Hard mode changes the odds
  (ctx.hard), so read game.Difficulty.

Shopkeepers (entity 17) -----------------------------------------------------------------------
  local r = DF.shopkeeper(npc.Variant, npc:GetDropRNG():GetSeed(), ctx, noReward)
  Variants 0 shop, 1 secret room (hanging), 2 error room; 3, 4 special (Greed 1/128).

Reward plate (grid type 20, variant 1) --------------------------------------------------------
  local r = DF.rewardPlate(g:GetSaveState().SpawnSeed, ctx)      -- while g.State == 0
  r.ambush = true: enemies instead of loot; otherwise r.roll (0-99) and loot, chests (r.chests with
  their contents from chest_forecast), a golden poop (r.poop with its coins), slots, an item,
  a trapdoor or a troll bomb.

Slot machines and beggars (entity 6) ----------------------------------------------------------
  local r = DF.slot(npc.Variant, npc:GetDropRNG():GetSeed(), ctx, n)   -- the next n payments
  ctx.payer = DF.payerContext(player)   -- who pays: Lucky Foot, PHD, Poker Chip, Keeper, Lost,
                                        -- golden key / bomb; nil = no items
  ctx.payer.counter = DF.slotCounter(npc.Variant, npc.InitSeed, npc:GetDropRNG():GetSeed(), ctx)
                        -- beggars 4, 5, 13, 18 keep a donation counter Lua cannot read: replayed
                        -- from the InitSeed (counter 0 at spawn); nil when the replay misses
  ctx.difficulty = game.Difficulty      -- hard mode changes most machines (DF.readContext sets it)
  r = { payments = { [i] = result (below) + kind, state (DropRNG after it), counter, ends =
        "leaves"|"breaks"|nil }, firstPrize = index of the first paying payment,
        unsupported = "Karma"|"Daemon's Tail"|... (then payments is empty) }
  Variants: 1 slot machine, 2 blood donation, 3 fortune teller, 4 beggar, 5 devil beggar, 7 key
  master, 9 bomb bum, 13 battery bum, 16 crane game, 18 rotten beggar. Luck is never read.
  DF.slotExplode(variant, seed, ctx): what it drops if blown up now.

Rooms not entered yet ---------------------------------------------------------------------------
  Layout spawn i (0-based index in desc.Data.Spawns) of a room with desc.SpawnSeed ss:
    DF.layoutSeed(ss, i)      = X11^(i+1)(ss): a grid's SpawnSeed (poops 1490-1501, plate 4500)
    DF.layoutInitSeed(ss, i)  = X35(layoutSeed): an entity's InitSeed = its DropRNG seed
                                (fireplaces 33/1400/1410, shopkeepers 17, slots 6)
  local r = DF.forLayout(stbType, stbVariant, ss, i, ctx)   -- dispatch on the STB code; nil if
                                                              -- the code is not a feature here
  Slots from the layout: a fresh machine (counter 0), ctx.slotPayments payments (12); a rotten
  beggar spawns as a key master while achievement 614 is locked (DF.slotVariant).
  The layout entry's kind must be the one the room spawns: spawns with several weighted entries
  and the room loader's own replacements (stage-based) are not modelled.

Results -----------------------------------------------------------------------------------------
  r = { groups = { {type=5, variant=, subtype=, count=} }, -- pickups, merged, spawn order
        entries = { {type, variant, subtype, seed, k, note?} },  -- k = position on the RNG chain
        items = { {pool=, pickSeed=, pedestalSeed=} },           -- collectibles: item_emulator
        fixedItem = id, trinket = id,                            -- fixed collectible / trinket
        nothing = bool, bad = "spiders"|"troll bomb"|"greed"|"ambush"|..., effect = "heal"|...,
        uncertain = { "..." } or nil, rng = "poop X1" ...  }
  Subtypes: subtype-0 pickups get theirs from RNG(seed, 35) on spawn; chest_forecast.resolve
  fills them in (ctx.resolve ~= false). Pills, cards, trinket ids stay 0 (not modelled).
  Items: picks = { {it.pool or Emu.poolForRoom(roomType), it.pickSeed} } -> emu:predictRoom.

ctx (all optional; missing = none):
  trinkets   = { [TrinketType] = summed GetTrinketMultiplier over players (Variant 0) }
               2 Petrified Poop, 22 Daemon's Tail, 24 Butt Penny, 91 Meconium (first holder's),
               plus chest_forecast's list for subtypes
  holders    = { [22] = {seed, ...}, [24] = {...}, [236] = {...} }  -- per player (Variant 0) in
               player order: GetTrinketRNG(22/24):GetSeed(), GetCollectibleRNG(236):GetSeed()
               (Daemon's Tail, Butt Penny, E. Coli). Their shift index is taken as 35 [U].
  hard       = Difficulty 1 or 3 (fireplaces, subtypes)        stage = level:GetStage()
  roomType   = room:GetType()                                  greed = game:IsGreedMode()
  trinketAvailable = fn(id) -> bool: trinket still in the trinket pool (not readable in vanilla
               Lua: IsAvailable and not seen this run). Default: available.
  isRemoved  = fn(collectibleId) -> bool (item_emulator: emu:isRemoved) for shopkeeper items
  trapdoorOk = bool: Level allows a trapdoor (reward plate roll < 5). Default: stage < 8.
  difficulty = game.Difficulty (slots: hard is 1, blood donation also 3)
  payer      = DF.payerContext(player) (+ counter) for slots      slotPayments = forLayout's n
  unlocked, collectibles, playerTypes ... : chest_forecast.resolve fields; slots also read
               147 (Blood Bag), 391 / 411 (bone / rotten heart), 614 (rotten beggar)
]]

local CF = include("chest_forecast")
local M = {}

local M32 = 0xFFFFFFFF
local SHIFT = {
  [1] = {1, 5, 16}, [4] = {1, 11, 6}, [7] = {1, 21, 20}, [8] = {1, 27, 27}, [11] = {2, 7, 7},
  [22] = {3, 5, 20}, [30] = {4, 3, 17},
  [35] = {5, 9, 7}, [39] = {5, 15, 17}, [54] = {7, 13, 25}, [55] = {7, 17, 21},
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

local f32
if string.pack then
  local pack, unpack = string.pack, string.unpack
  f32 = function(x) return (unpack("<f", pack("<f", x))) end
else
  f32 = function(x) return x + 0.0 end
end
local C_UNIT = f32(2.3283061589829401e-10)
--- RNG::RandomFloat on a Next() result: f32(f32(u32) * 2.3283061589829401e-10f)
local function rfloat(r) return f32(f32(r + 0.0) * C_UNIT) end
M.randomFloat = rfloat
local F001, F01, F02, F025, F04 = f32(0.01), f32(0.1), f32(0.2), f32(0.25), f32(0.4)

local function newRng(seed, idx) return { s = seed & M32, idx = idx, k = 0 } end
local function nxt(r) r.s = X(r.s, r.idx); r.k = r.k + 1; return r.s end

local function mult(ctx, t) return (ctx.trinkets or {})[t] or 0 end
local function trinketOk(ctx, t)
  local f = ctx.trinketAvailable
  if f == nil then return true end
  return f(t) == true
end

-- PlayerManager @0x9be3e0 / @0x9be140: among the holders (player order) the one whose
-- RandomFloat(X22^j(seed)) is largest; returns that player's RNG copy (shift 35 [U]) or nil.
-- cache: keeps each holder's RNG copy across several rolls (giga poop chunks).
local function holderRng(ctx, id, seed, cache)
  local list = ctx.holders and ctx.holders[id]
  if not list or #list == 0 then return nil end
  local best, chosen, s = -1.0, nil, seed
  for j = 1, #list do
    s = X(s, 22)
    local f = rfloat(s)
    if f > best then best, chosen = f, j end
  end
  local key = id * 16 + chosen
  if cache and cache[key] then return cache[key] end
  local r = newRng(list[chosen], ctx.holderShift or 35)
  if cache then cache[key] = r end
  return r
end

-- result builder
local function result(rngName)
  return { groups = {}, entries = {}, items = {}, rng = rngName }
end
local function note(r, s)
  r.uncertain = r.uncertain or {}
  for _, v in ipairs(r.uncertain) do if v == s then return end end
  r.uncertain[#r.uncertain + 1] = s
end
local function entry(r, t, v, s, seed, k)
  r.entries[#r.entries + 1] = { type = t, variant = v, subtype = s, seed = seed, k = k }
end
-- resolve subtype-0 pickups and merge into groups
local function finish(r, ctx)
  for _, e in ipairs(r.entries) do
    if e.type == 5 and e.subtype == 0 and e.seed and e.variant ~= 100 and ctx.resolve ~= false then
      local v, s, n = CF.resolve(e.variant, e.seed, ctx)
      e.spawnVariant, e.variant, e.subtype, e.note = e.variant, v, s, n
    end
    if e.type == 5 and e.variant == 100 and e.subtype == 0 then
      r.items[#r.items + 1] = { pool = e.pool, pickSeed = X(e.seed, 35), pedestalSeed = e.seed }
    else
      local merged = false
      for _, g in ipairs(r.groups) do
        if g.type == e.type and g.variant == e.variant and g.subtype == e.subtype then
          g.count = g.count + 1; merged = true; break
        end
      end
      if not merged then
        r.groups[#r.groups + 1] = { type = e.type, variant = e.variant, subtype = e.subtype, count = 1 }
      end
    end
  end
  if #r.groups == 0 and #r.items == 0 and not r.trinket and not r.fixedItem and not r.bad
      and not r.effect and not r.ambush and not r.trinkets and not r.poop and not r.slots then
    r.nothing = true
  end
  return r
end

-------------------------------------------------------------------------------
-- Poops
-------------------------------------------------------------------------------

M.POOP = { NORMAL = 0, RED = 1, CORNY = 2, GOLDEN = 3, RAINBOW = 4, BLACK = 5, WHITE = 6,
  GIGA = 7, CHARMING = 11 }
--- STB layout code -> grid poop variant
M.STB_POOP = { [1500] = 0, [1490] = 1, [1495] = 2, [1496] = 3, [1494] = 4, [1497] = 5, [1498] = 6,
  [1499] = 7, [1501] = 11 }

-- the drop chance of a poop pass (@0x7178c0 / @0x716db0): base, Butt Penny, Petrified Poop, flag
local function poopChance(ctx, base, passes, varFlag)
  local c = base
  local bp, pp = mult(ctx, 24), mult(ctx, 2)
  if bp > 0 then c = math.max(base, f32(f32(f32(bp + 0.0) * F01) + F02)) end
  if pp > 0 then c = math.max(f32(f32(f32(pp + 0.0) * F01) + F04), c) end
  if passes > 1 then c = math.max(F02, c) end
  if varFlag then c = F001 end
  return c
end

--- Drops of a grid poop destroyed (GridEntity_Poop::SpawnDrops @0x7178c0, one pass on RNG(seed, 1)).
function M.poop(variant, seed, ctx, varData)
  ctx = ctx or {}
  local r = result("poop X1")
  local varFlag = varData == 1
  local rng = newRng(seed, 1)
  local passes = ctx.passes or 1      -- 3 with hidden collectible 59 on the acting player [U]
  if variant == 1 then r.effect = "regrows"; return finish(r, ctx) end
  if variant == 4 then r.effect = "heal"; return finish(r, ctx) end           -- full heal, all players
  if variant >= 7 and variant <= 10 then note(r, "giga poop: use DF.gigaPoop"); return finish(r, ctx) end
  if variant == 11 then r.effect = "charmed dip"; return finish(r, ctx) end   -- per hit, not a pickup
  -- per-player RNGs drawn on X11 of the seed (only when someone holds the item)
  local d1 = X(seed, 11); local d2 = X(d1, 11); local d3 = X(d2, 11)
  local daemon = holderRng(ctx, 22, d1)
  local butt = holderRng(ctx, 24, d2)
  local ecoli = holderRng(ctx, 236, d3)
  if daemon or butt or ecoli then note(r, "player trinket RNG (shift 35 assumed)") end
  for _ = 1, passes do
    if variant == 0 or variant == 2 or variant == 6 then
      local c = poopChance(ctx, F01, passes, varFlag)
      local r1 = nxt(rng)
      if c > rfloat(r1) then
        local r2 = nxt(rng)
        if r2 % 20 == 0 and trinketOk(ctx, 2) then
          r.trinket = 2; entry(r, 5, 350, 2, nil, nil)            -- Petrified Poop (seed: Random())
        else
          local r3 = nxt(rng)
          local heart = rfloat(r3) < F025
          if heart and daemon and nxt(daemon) % 5 ~= 0 then heart = false end
          if heart and butt and nxt(butt) % 3 ~= 0 then heart = false end
          entry(r, 5, heart and 10 or 20, 0, nxt(rng), rng.k)
          if not trinketOk(ctx, 2) and r2 % 20 == 0 then note(r, "petrified poop not in pool") end
        end
      elseif ecoli and c > rfloat(nxt(ecoli)) then            -- E. Coli: a second chance at a heart
        local a = nxt(rng)
        if F001 > rfloat(a) or not varFlag then
          local b = nxt(rng)
          if rfloat(b) < F025 and (not daemon or nxt(daemon) % 5 == 0) then
            entry(r, 5, 10, 0, nxt(rng), rng.k)
          end
        end
      end
    elseif variant == 3 then                                   -- golden poop
      local r1 = nxt(rng)
      if r1 % 3 == 0 and trinketOk(ctx, 52) then
        entry(r, 5, 350, 52, nxt(rng), rng.k)                     -- Counterfeit Penny
        r.trinket = 52
        break
      end
      local n = nxt(rng) % 3 + 5
      if passes > 1 then n = (nxt(rng) & 1) + 2 end
      for _ = 1, n do entry(r, 5, 20, 0, nxt(rng), rng.k) end
    elseif variant == 5 then                                   -- black poop: Meconium black heart
      r.effect = "hurts enemies"
      local m = mult(ctx, 91)
      if m > 0 then
        local chance = m == 2 and 7 or (m == 3 and 10 or 5)
        if nxt(rng) % 100 < chance then entry(r, 5, 10, 6, nxt(rng), rng.k) end
      end
    end
  end
  if variant == 2 then note(r, "corny poop: eternal fly") end
  if mult(ctx, 86) > 0 then r.flies = mult(ctx, 86) end       -- Lil Larva: blue flies (not pickups)
  return finish(r, ctx)
end

--- Giga poop: drops of the damage chunks still to break (@0x716db0). seed and state are the
--- variant-9 part's SpawnSeed and State (0..1000, 20 per chunk). Each chunk j rolls on
--- X55 of X39^j(seed). Returns r with entries tagged chunk = j.
function M.gigaPoop(seed, state, ctx, varData)
  ctx = ctx or {}
  local r = result("giga poop X39/X55")
  local varFlag = varData == 1
  local done = (state or 0) // 20
  local s = seed & M32
  local cache = {}
  for _ = 1, done do s = X(s, 39) end
  for j = done + 1, 50 do
    s = X(s, 39)
    local u = X(s, 55)
    if u & 1 == 0 then
      local d1 = X(u, 55); local d2 = X(d1, 55); local d3 = X(d2, 55)
      local daemon, butt, ecoli = holderRng(ctx, 22, d1, cache), holderRng(ctx, 24, d2, cache), holderRng(ctx, 236, d3, cache)
      local c = poopChance(ctx, F025, 1, varFlag)
      local v = X(d3, 55)
      local function add(var, sd)
        entry(r, 5, var, 0, sd, j); r.entries[#r.entries].chunk = j
      end
      if c > rfloat(v) then
        local v2 = X(v, 55)
        if v2 % 20 == 0 and trinketOk(ctx, 2) then
          r.trinket = 2; entry(r, 5, 350, 2, nil, j)
        else
          local v3 = X(v2, 55)
          local heart = rfloat(v3) < F025
          if heart and daemon and nxt(daemon) % 5 ~= 0 then heart = false end
          if heart and butt and nxt(butt) % 3 ~= 0 then heart = false end
          add(heart and 10 or 20, X(v3, 55))
        end
      elseif ecoli and rfloat(nxt(ecoli)) < c then
        local a = X(v, 55)
        if rfloat(a) < F001 or not varFlag then
          local b = X(a, 55)
          if rfloat(b) < F025 and (not daemon or nxt(daemon) % 5 == 0) then add(10, X(b, 55)) end
        end
      end
    end
  end
  return finish(r, ctx)
end

-------------------------------------------------------------------------------
-- Fireplaces (entity 33): drop list @0x6d1580 on the DropRNG (shift 30)
-------------------------------------------------------------------------------

local FIRE_NODROP = { [4] = true, [10] = true, [11] = true, [12] = true, [13] = true }
function M.fireplace(variant, dropSeed, ctx, noReward)
  ctx = ctx or {}
  local r = result("fireplace DropRNG X30")
  if noReward or FIRE_NODROP[variant] then return finish(r, ctx) end
  local rng = newRng(dropSeed, 30)
  local c = ctx.hard and F01 or F025
  local daemon = mult(ctx, 22)
  if variant == 2 or variant == 3 then                -- blue, purple: soul heart
    if rfloat(nxt(rng)) < c then
      if daemon > 0 and X(rng.s, 4) % 5 ~= 0 then return finish(r, ctx) end
      entry(r, 5, 10, daemon >= 2 and 6 or 3, nxt(rng), rng.k)
    end
  else                                                -- normal, red
    if rfloat(nxt(rng)) < c then
      local heart = rfloat(nxt(rng)) < F025
      if heart and daemon > 0 and X(rng.s, 4) % 5 ~= 0 then heart = false end
      entry(r, 5, heart and 10 or 20, 0, nxt(rng), rng.k)
    end
  end
  return finish(r, ctx)
end

-------------------------------------------------------------------------------
-- Shopkeepers (entity 17): drop list @0x6c1ac0 on the DropRNG (shift 30)
-------------------------------------------------------------------------------

M.SHOPKEEPER_TRINKETS = { 1, 24, 49, 50, 51, 52 }   -- Swallowed/Butt/Bloody/Burnt/Flat/Counterfeit Penny
function M.shopkeeper(variant, dropSeed, ctx, noReward)
  ctx = ctx or {}
  local r = result("shopkeeper DropRNG X30")
  if noReward then return finish(r, ctx) end
  local rng = newRng(dropSeed, 30)
  local removed = ctx.isRemoved or function() return false end
  if variant == 3 or variant == 4 then                 -- special shopkeepers
    local a = nxt(rng)
    if a & 0x7f == 0 and ctx.roomType ~= 5 then
      r.bad = "greed"; r.greedSeed = nxt(rng)           -- Greed (entity 50.0) appears and fights
      return finish(r, ctx)
    end
    local b = nxt(rng)
    if b & 0x1f == 0 then
      for _ = 1, 3 do
        local t = M.SHOPKEEPER_TRINKETS[nxt(rng) % 6 + 1]
        if trinketOk(ctx, t) then entry(r, 5, 350, t, nxt(rng), rng.k); r.trinket = t; break end
      end
      return finish(r, ctx)
    end
    if nxt(rng) % 3 ~= 0 then entry(r, 5, 20, 2, nxt(rng), rng.k) end   -- a nickel
    return finish(r, ctx)
  end
  -- 0 shop, 1 secret room, 2 error room
  local a = nxt(rng)
  if a % 100 == 0 and not removed(64) then
    r.fixedItem = 64; entry(r, 5, 100, 64, nxt(rng), rng.k); return finish(r, ctx)  -- Steam Sale
  end
  if nxt(rng) % 100 == 0 and not removed(429) then
    r.fixedItem = 429; entry(r, 5, 100, 429, nxt(rng), rng.k); return finish(r, ctx) -- Head of the Keeper
  end
  if nxt(rng) % 100 == 0 then
    -- Coupon (521) when a game-state gate holds (not identified) and it is still in the pools
    note(r, "coupon gate unknown")
    if ctx.couponOk and not removed(521) then
      r.fixedItem = 521; entry(r, 5, 100, 521, nxt(rng), rng.k); return finish(r, ctx)
    end
  end
  local o = nxt(rng) % 3
  if o == 1 then
    r.bad = "spiders"; entry(r, 85, 0, 0, nxt(rng), rng.k); entry(r, 85, 0, 0, nxt(rng), rng.k)
  elseif o == 2 then
    entry(r, 5, 20, 0, nxt(rng), rng.k); entry(r, 5, 20, 0, nxt(rng), rng.k)
  end
  return finish(r, ctx)
end

-------------------------------------------------------------------------------
-- Reward plate (pressure plate variant 1): trigger @0x984550 on RNG(SpawnSeed, 35)
-------------------------------------------------------------------------------

M.PLATE_CHESTS = { 50, 60, 51, 360 }
function M.rewardPlate(seed, ctx)
  ctx = ctx or {}
  local r = result("reward plate X35")
  local rng = newRng(seed, 35)
  local x1 = nxt(rng)
  if x1 & 1 == 1 then
    r.ambush = true; r.bad = "ambush"     -- enemies by stage; seeds from X35^k(x1); not modelled
    return finish(r, ctx)
  end
  local roll = nxt(rng) % 100
  r.roll = roll
  local trapdoor = ctx.trapdoorOk
  if trapdoor == nil then trapdoor = (ctx.stage or 1) < 8; if roll < 5 and (ctx.stage or 1) >= 8 then note(r, "trapdoor rule") end end
  if roll < 5 and trapdoor then
    r.trapdoor = true; r.effect = "trapdoor"; nxt(rng)
  elseif roll < 11 then
    local sd = nxt(rng)
    local golden = roll < 10                                  -- 5..9 (and 0..4 without a trapdoor)
    r.poop = M.poop(golden and 3 or 0, sd, ctx, 0)            -- a grid poop with SpawnSeed sd
    r.poop.variant, r.poop.seed = golden and 3 or 0, sd
  elseif roll < 12 then
    local sd = nxt(rng)
    entry(r, 5, 100, 0, sd, rng.k)                            -- collectible of the room's pool
  elseif roll < 30 then
    for _ = 1, nxt(rng) % 3 + 1 do entry(r, 5, 20, 0, nxt(rng), rng.k) end
  elseif roll < 50 then
    for _ = 1, nxt(rng) % 2 + 1 do entry(r, 5, 10, 0, nxt(rng), rng.k) end
  elseif roll < 70 then
    for _ = 1, nxt(rng) % 2 + 1 do entry(r, 5, 40, 0, nxt(rng), rng.k) end
  elseif roll < 80 then
    local sd = nxt(rng); local k = rng.k
    local v = M.PLATE_CHESTS[nxt(rng) % 4 + 1]
    -- a chest with InitSeed sd: subtype from RNG(sd, 35) (brown/golden re-roll), contents from its
    -- DropRNG = RNG(sd, 30)
    local cv, cs = v, 1
    if (v == 50 or v == 60) and ctx.resolve ~= false then cv, cs = CF.resolve(v, sd, ctx) end
    r.chests = { { variant = cv, subtype = cs, seed = sd, k = k,
      contents = CF.predict(cv, cs, sd, ctx, sd) } }
    entry(r, 5, cv, cs, sd, k)
  elseif roll < 85 then
    local sd = nxt(rng)
    r.slots = { { variant = (nxt(rng) % 2 ~= 0) and 3 or 1, seed = sd } }   -- fortune teller / slot
  elseif roll < 90 then
    r.slots = { { variant = 8, seed = nxt(rng) } }             -- donation machine (6.8)
  else
    r.bad = "troll bomb"; entry(r, 4, 3, 0, nxt(rng), rng.k)
  end
  finish(r, ctx)
  if r.trapdoor then r.nothing = nil end
  return r
end

-------------------------------------------------------------------------------
-- Slot machines and beggars (entity 6): payment handler @0x6627e0, payouts at the "Prize" event
-- in Entity_Slot::Update @0x65d950, pickup spawns @0x6657a0, explosion drops @0x663aa0.
-- All on the machine's DropRNG (shift 30), one serial stream: a machine takes no payment until
-- the previous payout is done. Player Luck is never read.
-------------------------------------------------------------------------------

local Unsupported = {}
local function unsupported(msg) error({ [Unsupported] = msg }, 0) end
local function ri(r, m) local v = nxt(r); if m == 0 then return 0 end return v % m end
local function rf(r) return rfloat(nxt(r)) end
local F035, F055, F07, F085, F065, F046, F0002 = f32(0.35), f32(0.55), f32(0.7), f32(0.85), f32(0.65), f32(0.46), f32(0.002)

-- @0x6657a0: one copy per Poker Chip multiplier (max 3), each seeded with one Next()
local function sspawn(r, c, var, sub, list)
  list = list or {}
  local n = (c.pokerChip or 0) > 0 and math.min(c.pokerChip, 3) or 1
  for _ = 1, n do list[#list + 1] = { 5, var, sub or 0, nxt(r) } end
  return list
end
local function pay(kind, drops, extra)
  local t = { kind = kind, drops = drops or {} }
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return t
end

local function explodeDrops(variant, r, c)
  local d = {}
  if variant == 2 then                                  -- blood donation machine
    for _ = 1, ri(r, 2) + 1 do
      if c.daemonsTail then unsupported("Daemon's Tail") end
      if ri(r, 2) == 0 then for _ = 1, ri(r, 4) + 1 do d[#d + 1] = { 5, 20, 0, nxt(r) } end
      else d[#d + 1] = { 5, 10, 0, nxt(r) } end
    end
    return d
  end
  if variant == 5 or variant == 15 then return d end    -- two spiders seeded by Random()
  if variant == 18 or variant == 10 or variant == 12 or variant == 19 then
    unsupported("explosion branch for variant " .. variant)
  end
  if ri(r, 5) == 0 then d[1] = { 5, ri(r, 2) == 0 and 350 or 70, 0, nxt(r) }; return d end
  if rf(r) < F001 then d[1] = { 5, 50, 0, nxt(r) }; return d end
  if rf(r) < F001 then d[1] = { 5, 60, 0, nxt(r) }; return d end
  local n = math.max(2, ri(r, 4))
  if ri(r, 3) ~= 0 and c.luckyToeAny then n = n + 1 end
  local i = 0
  while i < n do
    local f = rf(r)
    if f < F035 then for _ = 1, ri(r, 3) + 1 do d[#d + 1] = { 5, 20, 0, nxt(r) } end
    elseif f < F055 and not c.daemonsTail then
      d[#d + 1] = { 5, 10, 0, nxt(r) }
      if ri(r, 2) == 0 then n = n - 1 end
    elseif f < F07 then d[#d + 1] = { 5, 30, 0, nxt(r) }
    else d[#d + 1] = { 5, 40, 0, nxt(r) } end
    i = i + 1
  end
  return d
end
local function boom(r, c, variant) return pay("breaks", explodeDrops(variant, r, c), { ends = "breaks" }) end
local function poolItem(pool, pickSeed, spawnSeed, ends)
  return pay("item", { { 5, 100, -1, spawnSeed } }, { item = { pool = pool, seed = pickSeed, spawnSeed = spawnSeed }, ends = ends })
end

local SLOT_PAYOUT = {}
SLOT_PAYOUT[2] = function(r, c)                        -- blood donation
  if ri(r, 100) == 0 and c.trinketOk(34) then
    return pay("trinket", { { 5, 350, 34, false } }, { note = "Child's Heart, seed Random()" })
  end
  if ri(r, 15) == 0 then
    local item = 135
    if ri(r, 2) == 0 or not c.itemOk(135) then item = c.unlocked(147) and 119 or 135 end
    return pay("item", { { 5, 100, item, nxt(r) } }, { ends = "breaks" })
  end
  local n
  if c.keeper then
    n = ri(r, 2)
    if c.phd and ri(newRng(r.s, 8), 4) == 0 then n = n + 1 end
  else
    if c.difficulty == 1 or c.difficulty == 3 then n = math.max(1, ri(r, 2)) else n = math.max(1, ri(r, 3)) end
    if c.phd then n = n + 1 end
  end
  local d = {}
  for _ = 1, n do sspawn(r, c, 20, 0, d) end
  return pay("coins", d)
end
SLOT_PAYOUT[4] = function(r, c)                        -- beggar
  if ri(r, 2) == 0 then
    if ri(r, 3) == 0 then
      if c.daemonsTail then unsupported("Daemon's Tail") end
      return pay("heart", sspawn(r, c, 10))
    end
    if ri(r, 2) == 0 then return pay("key", sspawn(r, c, 30)) end
    return pay("bomb", sspawn(r, c, 40))
  end
  if ri(r, 2) == 0 then
    if ri(r, 2) ~= 0 then return pay("card", sspawn(r, c, 300)) end
    local food = 22 + ri(r, 5)
    if c.lost then local ps = nxt(r); return poolItem(10, ps, nxt(r), "leaves") end
    return pay("item", { { 5, 100, food, nxt(r) } }, { ends = "leaves" })
  end
  local sd = nxt(r)
  return poolItem(10, nxt(r), sd, "leaves")
end
SLOT_PAYOUT[5] = function(r, c)                        -- devil beggar
  if ri(r, 2) == 0 then
    if ri(r, 2) == 0 then return pay("pill", sspawn(r, c, 70)) end
    return pay("card", sspawn(r, c, 300))
  end
  if ri(r, 4) == 0 then return pay("trinket", { { 5, 350, 0, nxt(r) } }) end
  local sd = nxt(r)
  return poolItem(11, nxt(r), sd, "leaves")
end
SLOT_PAYOUT[13] = function(r, c)                       -- battery bum
  if ri(r, 16) == 0 then local ps = nxt(r); return poolItem(14, ps, nxt(r), "leaves") end
  if ri(r, 8) == 0 then
    if ri(r, 10) == 0 and c.trinketOk(3) then return pay("trinket", { { 5, 350, 3, nxt(r) } }) end
    if ri(r, 10) == 0 and c.trinketOk(72) then return pay("trinket", { { 5, 350, 72, nxt(r) } }) end
    return pay("battery", sspawn(r, c, 90))
  end
  ri(r, 6)
  return pay("charge")                                  -- charges the active item
end
SLOT_PAYOUT[18] = function(r, c)                       -- rotten beggar
  if ri(r, 24) == 0 then local ps = nxt(r); return poolItem(30, ps, nxt(r), "leaves") end
  if ri(r, 4) == 0 then
    local r6 = ri(r, 6)
    if r6 == 0 and c.unlocked(391) then return pay("bone heart", sspawn(r, c, 10, 11)) end
    if r6 >= 1 and r6 <= 3 and c.unlocked(411) then return pay("rotten heart", sspawn(r, c, 10, 12)) end
    local idx = ri(newRng(r.s, 7), 8)                  -- a copy: the DropRNG does not move
    if idx < 4 then
      local t = ({ 29, 94, 71, 126 })[idx + 1]
      if c.trinketOk(t) then return pay("trinket", { { 5, 350, t, nxt(r) } }) end
    end
    return pay("fart")
  end
  if ri(r, 2) == 0 then return pay("blue flies", nil, { count = ri(r, 3) + 1 }) end
  return pay("blue spiders", nil, { count = ri(r, 3) + 1 })
end

local function slotMachine(r, c)
  if nxt(r) % 50 == 0 then return boom(r, c, 1) end
  local p
  if not c.luckyFoot and (not ((c.pokerChip or 0) > 0) or (nxt(r) & 3) ~= 0) then p = nxt(r) % 21 + 3
  else p = nxt(r) % 15 + 3 end
  if p == 9 then if nxt(r) % 10 >= 3 then p = 11 end
  elseif p == 10 then if nxt(r) % 10 >= 5 then p = 11 end
  elseif p > 10 then if nxt(r) % 10 ~= 0 then p = p + 1 end end
  if p == 7 and nxt(r) % 3 == 0 then p = 11 end
  if (p == 5 or p == 6) and c.daemonsTail then unsupported("Daemon's Tail") end
  if c.difficulty == 1 and (nxt(r) & 1) == 0 then p = 0 end
  if p < 3 or p > 13 then
    while true do
      local a, b, d = nxt(r) & 7, nxt(r) & 7, nxt(r) & 7
      if not (a == b and b == d) then break end
    end
    return pay("nothing")
  end
  if p == 3 then
    if ri(r, 3) == 0 then return pay("pretty fly") end
    return pay("fly", { { 13, 0, 0, nxt(r) } })
  end
  if p == 4 then return pay("bomb", sspawn(r, c, 40)) end
  if p == 5 or p == 6 then return pay("heart", sspawn(r, c, 10)) end
  if p == 7 then return pay("key", sspawn(r, c, 30)) end
  if p == 8 then return pay("pill", sspawn(r, c, 70)) end
  if p == 9 or p == 10 then return pay("item", { { 5, 100, p == 9 and 18 or 177, nxt(r) } }, { ends = "breaks" }) end
  local d = {}
  for _ = 1, math.max(1, ri(r, 3)) do sspawn(r, c, 20, 0, d) end
  return pay("coins", d)
end

local function fortuneTeller(r, c)
  local ch = c.difficulty == 1 and F085 or F065
  if c.luckyFoot or ((c.pokerChip or 0) > 0 and ri(r, 5) == 0) then ch = f32(ch * F046) end
  local f = rf(r)
  if ch > f then return pay("fortune") end
  if ri(r, 20) == 0 then return boom(r, c, 3) end
  if ri(r, 30) == 0 then return pay("item", { { 5, 100, 158, nxt(r) } }, { ends = "breaks" }) end   -- Crystal Ball
  if ri(r, 3) == 0 then return pay("card", sspawn(r, c, 300)) end
  if ri(r, 3) == 0 then
    if c.daemonsTail then unsupported("Daemon's Tail") end
    return pay("soul heart", sspawn(r, c, 10, 3))
  end
  return pay("trinket", { { 5, 350, 0, nxt(r) } })
end

local function craneGame(r, c, st)
  local v = (nxt(r) % 100) - ((c.pokerChip or 0) > 0 and 5 or 0)
  if v >= 25 then return pay("nothing") end
  local sd = nxt(r)
  local out = poolItem(23, st.craneSeed, sd)          -- the prize was picked with the state before
  st.craneSeed = r.s
  st.wins = st.wins + 1
  if st.wins >= 3 then out.ends = "leaves" end
  return out
end

-- beggar-type donation counter (@0x663566): true = this payment pays
local function counterPays(r, c, st, variant)
  if c.karma then unsupported("Karma") end
  st.counter = st.counter + 1
  local s, thr
  if variant == 13 or variant == 18 then
    s = ri(r, 3) + ri(r, 2); thr = c.difficulty == 1 and math.max(2, s) or s
  else
    s = ri(r, 4) + ri(r, 4) + ri(r, 2); thr = c.difficulty == 1 and math.max(5, s) or s
  end
  if st.counter > thr then
    st.counter = ri(r, 2) + 2 + (c.luckyFoot and 1 or 0)
    return true
  end
  return false
end

local function slotCtx(ctx)
  local p = ctx.payer or {}
  local u = ctx.unlocked
  local c = { difficulty = ctx.difficulty or (ctx.hard and 1 or 0), luckyToeAny = mult(ctx, 42) > 0,
    trinketOk = function(t) return trinketOk(ctx, t) end,
    itemOk = function(id) return not (ctx.isRemoved and ctx.isRemoved(id)) end,
    unlocked = function(a)
      if type(u) == "function" then return u(a) == true end
      if type(u) == "table" then return u[a] == true end
      return true
    end }
  for _, k in ipairs({ "luckyFoot", "pokerChip", "phd", "keeper", "goldenKey", "goldenBomb", "lost",
      "daemonsTail", "karma", "counter", "wins" }) do c[k] = p[k] end
  return c
end

local function slotRun(variant, seed, n, c)
  local r = newRng(seed, 30)
  local st = { counter = c.counter or 0, craneSeed = seed, wins = c.wins or 0 }
  local out = {}
  for _ = 1, n do
    local k0, x = r.k, nil
    if variant == 2 or variant == 1 or variant == 3 then
      if c.karma and variant ~= 2 then unsupported("Karma") end
      x = variant == 2 and SLOT_PAYOUT[2](r, c) or (variant == 1 and slotMachine(r, c) or fortuneTeller(r, c))
    elseif variant == 4 or variant == 5 or variant == 13 or variant == 18 then
      if counterPays(r, c, st, variant) then
        x = SLOT_PAYOUT[variant](r, c)
        if variant == 13 or variant == 18 then st.counter = 0 end
      else x = pay("nothing") end
    elseif variant == 7 then                            -- key master
      if c.karma then unsupported("Karma") end
      local roll = ri(r, 100)
      if c.goldenKey or roll < 35 then
        if ri(r, 8) == 0 or c.goldenKey then
          if not c.goldenKey and ri(r, 2) == 0 and c.trinketOk(19) then
            x = pay("trinket", { { 5, 350, 19, nxt(r) } }, { ends = "leaves" })   -- Paper Clip
          else local sd = nxt(r); x = poolItem(13, nxt(r), sd, "leaves") end
        else
          local sd = nxt(r)
          x = pay("chest", { { 5, ({ 50, 60, 360 })[ri(r, 3) + 1], 0, sd } })
        end
      else x = pay("nothing") end
    elseif variant == 9 then                            -- bomb bum
      local prize = 3
      if not c.goldenBomb then
        local v = ri(r, 100)
        prize = (v < 25 and 1) or (v < 35 and 2) or (v < 40 and 3) or 0
      end
      if prize == 1 then
        local d = {}
        for _ = 1, ri(r, 3) + 1 do sspawn(r, c, 20, 0, d) end
        x = pay("coins", d)
      elseif prize == 2 then
        if c.daemonsTail then unsupported("Daemon's Tail") end
        x = pay("heart", sspawn(r, c, 10))
      elseif prize == 3 then local sd = nxt(r); x = poolItem(25, nxt(r), sd, "leaves")
      else x = pay("nothing") end
    elseif variant == 16 then
      x = craneGame(r, c, st)
    else
      unsupported("slot variant " .. tostring(variant))
    end
    x.state, x.k, x.counter = r.s, r.k - k0, st.counter
    out[#out + 1] = x
    if x.ends then break end
  end
  return out
end

-- one payment's raw result -> the module's result format (subtypes resolved, items for emulator)
local function slotResult(x, ctx)
  local r = result("slot DropRNG X30")
  r.kind, r.ends, r.state, r.counter, r.k, r.count = x.kind, x.ends, x.state, x.counter, x.k, x.count
  for _, d in ipairs(x.drops) do
    if d[1] == 5 and d[2] == 100 and d[3] == -1 then
      r.items[#r.items + 1] = { pool = x.item.pool, pickSeed = x.item.seed, pedestalSeed = x.item.spawnSeed }
    elseif d[1] == 5 and d[2] == 100 then
      r.fixedItem = d[3]; entry(r, 5, 100, d[3], d[4] or nil, nil)
    else
      entry(r, d[1], d[2], d[3], d[4] or nil, nil)
      if not d[4] then note(r, x.note or "seed Random()") end
    end
  end
  if x.kind == "breaks" then r.bad = "breaks" end
  if x.kind == "nothing" or x.kind == "fortune" then
    finish(r, ctx); r.nothing = true; return r
  end
  if x.kind ~= "item" and x.kind ~= "breaks" and #x.drops == 0 then r.effect = x.kind end   -- charge, flies ...
  local items = r.items
  r.items = {}
  finish(r, ctx)
  r.items = items
  if #items > 0 then r.nothing = nil end
  return r
end

--- The next n payments to a slot machine or beggar (variant = entity Variant), from its DropRNG
--- state slot:GetDropRNG():GetSeed(). ctx.payer: the paying player (DF.payerContext); ctx.difficulty
--- = game.Difficulty. Beggar-type machines (4, 5, 13, 18) keep a donation counter Lua cannot read:
--- pass ctx.payer.counter (DF.slotCounter rebuilds it; 0 for a machine nobody has paid).
--- Returns r = { payments = { result per payment, + kind, state, counter, ends }, unsupported = msg }.
function M.slot(variant, dropSeed, ctx, n)
  ctx = ctx or {}
  local c = slotCtx(ctx)
  local ok, out = pcall(slotRun, variant, dropSeed, n or 10, c)
  if not ok then
    if type(out) == "table" and out[Unsupported] then return { payments = {}, unsupported = out[Unsupported] } end
    error(out, 0)
  end
  local r = { payments = {}, rng = "slot DropRNG X30" }
  for i, x in ipairs(out) do
    r.payments[i] = slotResult(x, ctx)
    if not r.firstPrize and not r.payments[i].nothing then r.firstPrize = i end
  end
  return r
end

--- What a slot machine or beggar drops if blown up now (@0x663aa0).
function M.slotExplode(variant, dropSeed, ctx)
  ctx = ctx or {}
  local c = slotCtx(ctx)
  local rng = newRng(dropSeed, 30)
  local ok, d = pcall(explodeDrops, variant, rng, c)
  if not ok then
    if type(d) == "table" and d[Unsupported] then return { payments = {}, unsupported = d[Unsupported] } end
    error(d, 0)
  end
  return slotResult(pay("breaks", d, { ends = "breaks", state = rng.s, k = rng.k }), ctx)
end

--- Donation counter of a beggar-type machine: replay from its InitSeed (counter 0 at spawn) until the
--- DropRNG state equals curSeed. Returns the counter, or nil when no replay reaches curSeed (or
--- several do with different counters), and the number of payments.
function M.slotCounter(variant, initSeed, curSeed, ctx, maxPayments)
  ctx = ctx or {}
  local c = slotCtx(ctx)
  c.counter = 0
  if initSeed == curSeed then return 0, 0 end
  local s, counter, found, pays = initSeed, 0, nil, nil
  for i = 1, maxPayments or 200 do
    c.counter = counter
    local ok, out = pcall(slotRun, variant, s, 1, c)
    if not ok then return nil end
    s, counter = out[1].state, out[1].counter
    if s == curSeed then
      if found and found ~= counter then return nil end
      found, pays = counter, i
    end
    if out[1].ends then break end
  end
  return found, pays
end

--- The paying player's part of a slot context (pure reads).
function M.payerContext(player)
  local t = player:GetPlayerType()
  return { luckyFoot = player:HasCollectible(46), phd = player:HasCollectible(75),
    pokerChip = player:HasTrinket(76) and math.max(1, player:GetTrinketMultiplier(76)) or 0,
    keeper = t == 14 or t == 33, goldenKey = player:HasGoldenKey(), goldenBomb = player:HasGoldenBomb(),
    lost = t == 31 or (t == 10 and player:HasCollectible(619)),
    daemonsTail = player:HasTrinket(22), karma = player:HasTrinket(85) }
end

-------------------------------------------------------------------------------
-- Rooms not entered yet
-------------------------------------------------------------------------------

--- Seed the game gives layout spawn i (0-based) of a room: X11^(i+1)(SpawnSeed). It is a grid's
--- SpawnSeed; an entity's InitSeed is X35 of it (DF.layoutInitSeed).
function M.layoutSeed(spawnSeed, i)
  local x = spawnSeed & M32
  for _ = 0, i do x = X(x, 11) end
  return x
end
function M.layoutInitSeed(spawnSeed, i) return X(M.layoutSeed(spawnSeed, i), 35) end

local STB_FIRE = { [1400] = 0, [1410] = 1 }
--- Seed kind of a layout code: "grid" (SpawnSeed) or "entity" (InitSeed = DropRNG seed), or nil.
function M.seedKind(stbType)
  if M.STB_POOP[stbType] or stbType == 4500 then return "grid" end
  if stbType == 33 or STB_FIRE[stbType] or stbType == 17 or stbType == 6 then return "entity" end
  return nil
end
--- The seed a feature's forecast takes, for layout spawn i of a room with SpawnSeed ss.
function M.featureSeed(spawnSeed, i, stbType)
  local kind = M.seedKind(stbType)
  if kind == "grid" then return M.layoutSeed(spawnSeed, i), kind end
  if kind == "entity" then return M.layoutInitSeed(spawnSeed, i), kind end
  return nil
end

--- Slot kinds the room loader replaces while their achievement is locked (seen: a rotten beggar
--- spawned as a key master, achievement 614 missing; the replacement code was not read).
M.SLOT_LOCKED = { [18] = { achievement = 614, becomes = 7 } }
--- The slot variant a layout entry spawns as; second value: a note when the unlock is unknown.
function M.slotVariant(stbVariant, ctx)
  local rule = M.SLOT_LOCKED[stbVariant]
  if not rule then return stbVariant end
  local u = ctx and ctx.unlocked
  if type(u) == "function" then return u(rule.achievement) and stbVariant or rule.becomes end
  if type(u) == "table" then return u[rule.achievement] and stbVariant or rule.becomes end
  return stbVariant, "unlock " .. rule.achievement .. " unknown"
end

--- Forecast for layout spawn i (STB code stbType.stbVariant) of a room with SpawnSeed ss.
function M.forLayout(stbType, stbVariant, spawnSeed, i, ctx)
  local seed = M.featureSeed(spawnSeed, i, stbType)
  if not seed then return nil end
  if M.STB_POOP[stbType] then
    local v = M.STB_POOP[stbType]
    if v == 7 then
      local r = result("giga poop"); note(r, "giga poop: part-9 seed unknown before entry"); return r
    end
    return M.poop(v, seed, ctx, 0)
  end
  if stbType == 4500 then
    if stbVariant ~= 1 then return nil end
    return M.rewardPlate(seed, ctx)
  end
  if stbType == 33 or STB_FIRE[stbType] then
    return M.fireplace(STB_FIRE[stbType] or stbVariant, seed, ctx)
  end
  if stbType == 17 then return M.shopkeeper(stbVariant, seed, ctx) end
  if stbType == 6 then
    -- nobody has paid it yet: counter 0. ctx.payer = whoever will pay (nil: no items).
    local v, n = M.slotVariant(stbVariant, ctx)
    local r = M.slot(v, seed, ctx, ctx and ctx.slotPayments or 12)
    r.variant = v
    if n then r.uncertain = { n } end
    return r
  end
  return nil
end

-------------------------------------------------------------------------------
-- Context from the game (pure reads only)
-------------------------------------------------------------------------------

-- chest_forecast.readContext already sums 22 (Daemon's Tail) and its other trinkets
local EXTRA_TRINKETS = { 2, 24, 86, 91 }     -- 42 Lucky Toe comes from chest_forecast
--- chest_forecast's context plus what poops and fireplaces read. unlocked: achievement ids.
function M.readContext(game, unlocked)
  local ctx = CF.readContext(game, nil, unlocked)
  ctx.difficulty = game.Difficulty
  ctx.holders = { [22] = {}, [24] = {}, [236] = {} }
  for i = 0, game:GetNumPlayers() - 1 do
    local p = Isaac.GetPlayer(i)
    if p and p.Variant == 0 then
      for _, t in ipairs(EXTRA_TRINKETS) do
        if p:HasTrinket(t) then
          local m = math.max(1, p:GetTrinketMultiplier(t))
          if t == 91 then ctx.trinkets[t] = ctx.trinkets[t] or m      -- first holder's multiplier
          else ctx.trinkets[t] = (ctx.trinkets[t] or 0) + m end
        end
      end
      if p:HasTrinket(22) then local h = ctx.holders[22]; h[#h + 1] = p:GetTrinketRNG(22):GetSeed() end
      if p:HasTrinket(24) then local h = ctx.holders[24]; h[#h + 1] = p:GetTrinketRNG(24):GetSeed() end
      if p:HasCollectible(236) then local h = ctx.holders[236]; h[#h + 1] = p:GetCollectibleRNG(236):GetSeed() end
    end
  end
  return ctx
end

return M
