--[[
sacrifice_forecast.lua - what the next sacrifices on a sacrifice room's spikes give, before anyone
steps on them, in the room the players are in or in a room not entered yet; and what Sanguine
Bond's spikes give next. The Binding of Isaac: Repentance+ v1.9.7.17.J460, vanilla (no
REPENTOGON). Pure Lua 5.3: no game calls except in M.readContext (pure reads), never an
RNG:Next() on a game RNG.

Reconstructed from isaac-ng.exe (native/research/sacrifice-room.md): spike damage on a player
@0x709fb0 (from GridEntity_Spikes::Update @0x71e9b0 via @0x70b170), the sacrifice branch from
@0x70a309, reward jump table @0x70b140 (cases @0x70a6a3..@0x70ada0, 12th and later @0x70adf6),
Sanguine Bond branch @0x70a3c6; spike init (sprite variant and RNG seed) @0x71e11d.

  local SF = include("sacrifice_forecast")
  local ctx = SF.readContext(Game())         -- or build the table yourself (below)

In the room (grid type 8 GRID_SPIKES in a ROOM_SACRIFICE, sprite variant 1-4) --------------------
  local list = SF.forecast(spike:GetRNG():GetSeed(), spike.VarData, ctx, n)   -- next n (default 3)
  seed     the spike's own RNG (grid +0x2c, shift X35). The game keeps it in the desc's
           VariableSeed (GetSaveState().VariableSeed) between visits; both read the same.
  VarData  how many sacrifices were made on this spike so far (both players count, revisits keep
           it). The next one is number VarData + 1.
  ctx.done the room's RoomDescriptor FLAG_SACRIFICE_DONE (1 << 2): the spikes still hurt but give
           nothing and nothing advances; forecast returns {} then.

A room not entered yet --------------------------------------------------------------------------
  local list = SF.forLayout(roomSpawnSeed, i, ctx, n)   -- i = index of the STB 1930 entry in
                                                          -- desc.Data.Spawns (0-based)
  The spike's SpawnSeed is X11^(i+1)(room SpawnSeed); its first Init sets the sprite variant to
  (X35(SpawnSeed) & 3) + 1 and the RNG (and VariableSeed) to X35^2(SpawnSeed).

Outcomes (one per sacrifice, in order) ----------------------------------------------------------
  { n = sacrifice number, kind = (below), desc = short English text for the log,
    spawns = { {type, variant, subtype, seed} },    -- what spawns, with InitSeeds (subtype -1:
                                                     -- the angel item, see item.pickSeed)
    rng = spike RNG seed after it (the next sacrifice starts here) }
  kind      what (extra fields)
  nothing   -
  penny     5.20.1 (1st and 2nd: 50 %)
  bomb      5.40.1 (1st and 2nd when game state flag 16 is set and player 1 has no bombs)
  angelChance  angelChance = 0.15 (3rd, 50 %) or 0.5 (5th, 50 %): "You feel blessed!"
  chest     5.50 (4th 50 %, 6th 2/3): chest = {variant, subtype, seed, contents = chest_forecast}
  coins     coins = 3 (5th, 50 %) or 30 (10th, 50 %): pennies 5.20.1
  angelTeleport   6th, 1/3: teleport to an angel room (Level devil/angel room)
  angelItem 7th, 1/3: item = {pool = 4, pickSeed, spawnSeed}  -> item_emulator (the pick removes it
            from the angel pool)
  soulHeart 7th otherwise: 5.10.3; orRedemption = true when the Redemption rule (1/3 of these)
            could not be decided from ctx
  redemption  7th, 1/3, with a devil deal taken, before stage 7, Redemption still in the pools:
            fixedItem = 673 (5.100.673)
  trollBombs  8th: 7 troll bombs, one every 5 frames (their seeds are Random(): not forecast)
  boss      9th Uriel (271), 11th Gabriel (272): boss = id
  soulHearts  10th, 50 %: 7 soul hearts 5.10.3
  darkRoom  12th and later, 50 %: to the Dark Room (teleport = "darkroom"; in the Dark Room itself
            back to its start room, teleport = "start"). Never in Greed mode; a challenge's own end
            stage may forbid it (uncertain).
  Each sacrifice's rolls come from a copy RNG(X35(spike seed), shift 2): t1 = X2(s0) picks the
  case (t1 % 2 or % 3), the next steps are the spawns' InitSeeds.

Sanguine Bond (spikes variant 101-104, devil rooms) -------------------------------------------
  local o = SF.sanguine(spike:GetRNG():GetSeed(), ctx)     -- the next one; o.rng chains
  kind: coins (6 pennies) | damage (Sanguine Bond's damage effect) | blackHearts (2 x 5.10.6) |
        item (5.100.0 from the room's pool: item = {pickSeed, spawnSeed}) | leviathan (3 towards
        Leviathan) | nothing. f = the roll (EID lists the same thresholds).

ctx (all optional):
  done        FLAG_SACRIFICE_DONE of this room (in-room forecasts only)
  shovel      game:GetStateFlag(16)        bombs = Isaac.GetPlayer(0):GetNumBombs()
  devilDeals  game:GetDevilRoomDeals()     stage = level:GetStage()   stageType = level:GetStageType()
  redemptionAvailable  true/false: Redemption can still come from the pools (unlocked, not taken,
              not removed); nil = unknown (soulHeart with orRedemption)
  greed       Greed mode (Difficulty 2/3)   challenge = game.Challenge
  resolve     false: skip chest_forecast for chests; other chest_forecast fields (unlocked,
              trinkets, ...) are passed to it
]]

local CF = include("chest_forecast")
local M = {}

local M32 = 0xFFFFFFFF
local SHIFT = { [2] = {1, 5, 19}, [11] = {2, 7, 7}, [35] = {5, 9, 7} }
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
local function rfloat(r) return f32(f32(r + 0.0) * C_UNIT) end

M.ROOM_SACRIFICE = 13
M.GRID_SPIKES = 8
M.STB_SPIKES = 1930
M.FLAG_SACRIFICE_DONE = 1 << 2
M.ANGEL_POOL = 4
M.REDEMPTION = 673

--- The SpawnSeed of layout spawn i (0-based) of a room with SpawnSeed ss.
function M.layoutSeed(ss, i)
  local s = ss & M32
  for _ = 0, i do s = X(s, 11) end
  return s
end
--- The spike's RNG seed before its first sacrifice, from its SpawnSeed (Init @0x71e11d).
function M.initialRngSeed(spawnSeed) return X(X(spawnSeed, 35), 35) end
--- The sprite variant (1-4) the first Init gives a layout spike (STB 1930 variant 0).
function M.spriteVariant(spawnSeed) return (X(spawnSeed, 35) & 3) + 1 end

local function chestOf(o, seed, ctx)
  local v, s = 50, 1
  if ctx.resolve ~= false then v, s = CF.resolve(50, seed, ctx) end
  o.chest = { variant = v, subtype = s, seed = seed,
    contents = ctx.resolve ~= false and CF.predict(v, s, seed, ctx, seed) or nil }
  o.spawns[#o.spawns + 1] = { 5, v, s, seed }
end

local DESC = {
  nothing = "nothing", penny = "penny", bomb = "bomb", chest = "chest", angelTeleport = "angel room teleport",
  angelItem = "angel room item", soulHeart = "soul heart", redemption = "Redemption",
  trollBombs = "7 troll bombs", soulHearts = "7 soul hearts", darkRoom = "Dark Room",
}

-- One sacrifice with the spike RNG at g, number n.
local function one(g, n, ctx)
  local s0 = X(g, 35)                 -- the spike's RNG Next(): kept as its new state
  local t = s0                        -- the copy RNG(s0, shift 2) the rolls come from
  local function nx() t = X(t, 2); return t end
  local o = { n = n, rng = s0, spawns = {} }
  local function spawn(v, sub, seed) o.spawns[#o.spawns + 1] = { 5, v, sub, seed } end
  local c = n - 1                     -- VarData before it (the jump table index)
  if c <= 1 then
    if ctx.shovel and (ctx.bombs or 1) <= 0 then
      nx(); spawn(40, 1, nx()); o.kind = "bomb"
    elseif nx() % 2 == 0 then spawn(20, 1, nx()); o.kind = "penny"
    else o.kind = "nothing" end
  elseif c == 2 then
    if nx() % 2 == 0 then o.kind, o.angelChance = "angelChance", 0.15 else o.kind = "nothing" end
  elseif c == 3 then
    if nx() % 2 == 0 then o.kind = "chest"; chestOf(o, nx(), ctx) else o.kind = "nothing" end
  elseif c == 4 then
    if nx() % 2 == 0 then o.kind, o.angelChance = "angelChance", 0.5
    else
      o.kind, o.coins = "coins", 3
      for _ = 1, 3 do spawn(20, 1, nx()) end
    end
  elseif c == 5 then
    if nx() % 3 == 0 then o.kind, o.teleport = "angelTeleport", "angel"
    else o.kind = "chest"; chestOf(o, nx(), ctx) end
  elseif c == 6 then
    local r = nx() % 3
    if r == 0 then
      local spawnSeed = nx()
      o.kind = "angelItem"
      o.item = { pool = M.ANGEL_POOL, pickSeed = nx(), spawnSeed = spawnSeed }
      o.spawns[#o.spawns + 1] = { 5, 100, -1, spawnSeed }
    else
      local redeem = false
      if r == 2 then
        if (ctx.devilDeals or 0) > 0 and (ctx.stage or 1) < 7 then
          if ctx.redemptionAvailable == nil then o.orRedemption = true
          else redeem = ctx.redemptionAvailable == true end
        elseif ctx.devilDeals == nil and (ctx.stage or 1) < 7 then
          o.orRedemption = true
        end
      end
      if redeem then
        o.kind, o.fixedItem = "redemption", M.REDEMPTION; spawn(100, M.REDEMPTION, nx())
      else
        o.kind = "soulHeart"; spawn(10, 3, nx())
      end
    end
  elseif c == 7 then o.kind, o.bad = "trollBombs", true
  elseif c == 8 then o.kind, o.boss = "boss", 271; o.spawns[#o.spawns + 1] = { 271, 0, 0, nx() }
  elseif c == 9 then
    if nx() % 2 == 0 then
      o.kind = "soulHearts"
      for _ = 1, 7 do spawn(10, 3, nx()) end
    else
      o.kind, o.coins = "coins", 30
      for _ = 1, 30 do spawn(20, 1, nx()) end
    end
  elseif c == 10 then o.kind, o.boss = "boss", 272; o.spawns[#o.spawns + 1] = { 272, 0, 0, nx() }
  else
    if nx() % 2 ~= 0 or ctx.greed then o.kind = "nothing"
    else
      o.kind = "darkRoom"
      o.teleport = (ctx.stage == 11 and ctx.stageType == 0) and "start" or "darkroom"
      if ctx.challenge and ctx.challenge ~= 0 then o.uncertain = "challenge end stage" end
    end
  end
  if o.kind == "angelChance" then o.desc = string.format("+%d%% angel room chance", math.floor(o.angelChance * 100 + 0.5))
  elseif o.kind == "coins" then o.desc = o.coins .. " pennies"
  elseif o.kind == "boss" then o.desc = o.boss == 271 and "Uriel" or "Gabriel"
  elseif o.kind == "soulHeart" and o.orRedemption then o.desc = "soul heart or Redemption"
  else o.desc = DESC[o.kind] end
  return o
end

--- The next n (default 3) sacrifices on a spike whose RNG seed is seed and VarData count.
function M.forecast(seed, count, ctx, n)
  ctx = ctx or {}
  local out = {}
  if ctx.done then return out end
  local g = seed & M32
  for j = 1, n or 3 do
    local o = one(g, (count or 0) + j, ctx)
    out[j] = o
    g = o.rng
  end
  return out
end

--- A room not entered yet: the spike is layout spawn i of a room with SpawnSeed ss.
function M.forLayout(ss, i, ctx, n)
  return M.forecast(M.initialRngSeed(M.layoutSeed(ss, i)), 0, ctx, n)
end

--- Sanguine Bond's spikes (variant >= 100): the next roll.
local T015, T048, T058, T063, T065 = f32(0.15), f32(0.48), f32(0.58), f32(0.63), f32(0.65)
function M.sanguine(seed, ctx)
  local s0 = X(seed, 35)
  local t = X(s0, 2)
  local f = rfloat(t)
  local o = { rng = s0, f = f, spawns = {} }
  local function nx() t = X(t, 2); return t end
  if f < T015 then
    o.kind, o.coins = "coins", 6
    for _ = 1, 6 do o.spawns[#o.spawns + 1] = { 5, 20, 1, nx() } end
  elseif f < T048 then o.kind = "damage"
  elseif f < T058 then
    o.kind = "blackHearts"
    for _ = 1, 2 do o.spawns[#o.spawns + 1] = { 5, 10, 6, nx() } end
  elseif f < T063 then
    local s = nx()
    o.kind, o.item = "item", { pickSeed = X(s, 35), spawnSeed = s }
    o.spawns[#o.spawns + 1] = { 5, 100, 0, s }
  elseif f < T065 then o.kind = "leviathan"
  else o.kind = "nothing" end
  o.desc = o.kind
  return o
end

--- Context from the game (pure reads only), on top of chest_forecast's (chest contents).
function M.readContext(game, unlocked)
  return M.addContext(CF.readContext(game, nil, unlocked), game)
end
--- The sacrifice fields (pure reads) added to an existing chest_forecast context.
function M.addContext(ctx, game)
  local level = game:GetLevel()
  ctx.stage = ctx.stage or level:GetStage()
  ctx.stageType = level:GetStageType()
  ctx.greed = game:IsGreedMode()
  ctx.challenge = game.Challenge
  if game.GetDevilRoomDeals then ctx.devilDeals = game:GetDevilRoomDeals() end
  local ok, flag = pcall(function() return game:GetStateFlag(16) end)
  ctx.shovel = ok and flag == true
  local p0 = Isaac.GetPlayer(0)
  ctx.bombs = p0 and p0:GetNumBombs() or nil
  local desc = level:GetCurrentRoomDesc()
  ctx.done = desc ~= nil and desc.Flags ~= nil and (desc.Flags & M.FLAG_SACRIFICE_DONE) ~= 0
  -- Redemption: gone once anyone holds it or it is locked; whether the pools still have it
  -- otherwise is the item emulator's to say (left nil = unknown).
  for i = 0, game:GetNumPlayers() - 1 do
    local p = Isaac.GetPlayer(i)
    if p and p:HasCollectible(M.REDEMPTION) then ctx.redemptionAvailable = false end
  end
  local config = Isaac.GetItemConfig and Isaac.GetItemConfig()
  local item = config and config:GetCollectible(M.REDEMPTION)
  if item and item.IsAvailable and not item:IsAvailable() then ctx.redemptionAvailable = false end
  return ctx
end

return M
