-- Room-feature drop forecast: replay the logged runs through drop_forecast.lua
-- (native/research/room-feature-drops.md). Data: native/tests/data/drop_forecast_cases.lua, made by
-- tools/gen_drop_forecast_cases.py from the logs (observations only; the model lives here).
--  1. layout seeds: every logged spawn seed of a room is X11^(i+1)(room SpawnSeed) for a spawn
--     index i that grows in log order (DF.layoutSeed), and DF.featureSeed gives each feature's seed.
--  2. poops / fireplaces / reward plates / shopkeepers: every pickup found on a feature's RNG
--     chain must be predicted at that chain position with that variant, under the logged context
--     (hard mode; trinkets added before the drop). Features with no such pickup were not broken
--     or gave nothing; their predicted shares are printed.
--  3. subtypes of those pickups through chest_forecast.resolve with the save's unlocks.
--  4. DF.forLayout from (room SpawnSeed, spawn index, STB code) equals the in-room forecast.
-- Run from the project root: lua native/tests/drop_forecast_regression.lua [-v]
function include(name) return dofile("mod/isaac_dodge_assist/" .. name .. ".lua") end
local DF = include("drop_forecast")
local cases = dofile("native/tests/data/drop_forecast_cases.lua")
local VERBOSE = arg and arg[1] == "-v"

local fails = 0
local function check(cond, msg)
  if not cond then fails = fails + 1; print("FAIL " .. msg) end
  return cond
end
local function set(list) local s = {} for _, v in ipairs(list or {}) do s[v] = true end return s end

local unlocked = cases.unlocked and set(cases.unlocked) or nil
local trinketLocked = set(cases.trinketLocked)

local function ctxFor(run, f, opts)
  opts = opts or {}
  local tr = set(f.tr)
  local trinkets = {}
  for t in pairs(tr) do trinkets[t] = 1 end
  if opts.noTrinkets then trinkets = {} end
  return { trinkets = trinkets, collectibles = set(f.co), playerTypes = set(run.types),
    hard = opts.hard ~= false, stage = f.stage, roomType = f.rtype, unlocked = unlocked,
    -- a trinket is in the pool unless the save lacks it or the run already had it
    trinketAvailable = function(t) return not trinketLocked[t] and not tr[t] end }
end

-- predicted {k, variant} of pickups on the chain (spawnVariant: as initialised; the log shows the
-- variant after Init, which for chests is the re-rolled one)
local function chainKinds(r)
  local out = {}
  for _, e in ipairs(r.entries) do
    if e.k and e.type == 5 then out[#out + 1] = { e.k, e.variant, e.subtype } end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end
local function same(pred, hits, subtypes)
  if #pred ~= #hits then return false end
  for i = 1, #pred do
    if pred[i][1] ~= hits[i][1] or pred[i][2] ~= hits[i][2] then return false end
    if subtypes and pred[i][3] ~= hits[i][3] then return false end
  end
  return true
end
local function fmt(rows)
  local t = {}
  for _, r in ipairs(rows) do t[#t + 1] = "{" .. table.concat(r, ",") .. "}" end
  return "{" .. table.concat(t, ",") .. "}"
end

---------------------------------------------------------------------------- 1. layout seeds
do
  local rooms, spawns, ok = 0, 0, 0
  for _, run in ipairs(cases.runs) do
    for _, room in ipairs(run.rooms or {}) do
      rooms = rooms + 1
      -- index of each logged seed on the X11 chain
      local pos, x = {}, room.ss
      for i = 0, 400 do
        local s = DF.layoutSeed(room.ss, i)
        if pos[s] == nil then pos[s] = i end
      end
      local last = -1
      for _, sp in ipairs(room.spawns) do
        spawns = spawns + 1
        local i = pos[sp[3]]
        if check(i ~= nil and i > last, ("layout seed %s %d.%d seed %d not at a later X11 index"):format(run.run, room.type, room.variant, sp[3])) then
          ok = ok + 1; last = i
        end
      end
    end
  end
  print(("PASS layout seeds: %d / %d logged spawn seeds of %d rooms = X11^(i+1)(SpawnSeed), i rising"):format(ok, spawns, rooms))
end

---------------------------------------------------------------------------- 2./3. replay
local function spawnIndex(ss, seed)
  if not ss then return nil end
  for i = 0, 400 do if DF.layoutSeed(ss, i) == seed then return i end end
  return nil
end

local stats = {}
local function count(key, n) stats[key] = (stats[key] or 0) + (n or 1) end

local function replay(kind, label, predict, layoutCode)
  local hit, okHits, subOk, subN, needTr = 0, 0, 0, 0, 0
  for _, run in ipairs(cases.runs) do
    for _, f in ipairs(run[kind] or {}) do
      local ctx = ctxFor(run, f)
      local r = predict(f, ctx)
      local pred = chainKinds(r)
      local outcome = r.nothing and "nothing" or (r.bad or (r.trinket and "trinket") or (r.effect) or
        (#pred > 0 and "pickups") or (#r.items > 0 and "item") or "other")
      count(label .. " " .. outcome)
      -- 4. the unvisited-room path gives the same forecast
      local i = spawnIndex(f.ss, f.seed)
      if i and layoutCode then
        local t, v = layoutCode(f)
        local r2 = DF.forLayout(t, v, f.ss, i, ctx)
        if r2 then
          count("forLayout " .. label)
          check(same(chainKinds(r2), pred, true), ("forLayout %s %s seed %d"):format(label, run.run, f.seed))
        end
      end
      if #f.hits > 0 then
        hit = hit + 1
        if check(same(pred, f.hits), ("%s %s seed %d v%d: predicted %s, logged %s"):format(label, run.run,
            f.seed, f.v, fmt(pred), fmt(f.hits))) then
          okHits = okHits + 1
          if #f.tr > 0 and not same(chainKinds(predict(f, ctxFor(run, f, { noTrinkets = true }))), f.hits) then
            needTr = needTr + 1
          end
          for j = 1, #pred do
            subN = subN + 1
            if pred[j][3] == f.hits[j][3] then subOk = subOk + 1
            elseif VERBOSE then print(("  subtype %s %s seed %d k%d: %d.%d vs %d.%d"):format(label, run.run, f.seed,
              pred[j][1], pred[j][2], pred[j][3], f.hits[j][2], f.hits[j][3])) end
          end
        end
        if VERBOSE then print(("  %s %s seed %d: %s"):format(label, run.run, f.seed, fmt(f.hits))) end
      end
    end
  end
  print(("PASS %s: %d / %d features with logged drops at the predicted chain positions (%d of them only with the held trinkets); subtypes %d / %d"):format(
    label, okHits, hit, needTr, subOk, subN))
  return hit, okHits, subOk, subN
end

replay("poops", "poops", function(f, ctx) return DF.poop(DF.STB_POOP[f.t], f.seed, ctx, 0) end,
  function(f) return f.t, f.v end)
replay("fires", "fireplaces", function(f, ctx) return DF.fireplace(f.v, DF.next(f.seed, 35), ctx) end,
  function(f) return 33, f.v end)
replay("plates", "reward plates", function(f, ctx)
  if f.v ~= 1 then return { entries = {}, items = {}, nothing = true, bad = "plain plate" } end
  return DF.rewardPlate(f.seed, ctx)
end, function(f) return 4500, f.v end)
replay("keepers", "shopkeepers", function(f, ctx) return DF.shopkeeper(f.v, DF.next(f.seed, 35), ctx) end,
  function(f) return 17, f.v end)

-- predicted shares, and the hard-mode evidence: normal-mode-only fireplace drops never show
do
  -- rooms not entered yet, the way the mod sees them: STB code + room SpawnSeed + spawn index
  -- (post-0.25 logs, layouts rebuilt from the extracted STB files)
  local n, hit, ok, subOk, subN, slots = 0, 0, 0, 0, 0, 0
  for _, run in ipairs(cases.runs) do
    for _, f in ipairs(run.stb or {}) do
      local r = f.t ~= 6 and DF.forLayout(f.t, f.v, f.ss, f.i, ctxFor(run, f)) or nil
      if r == nil then
        slots = slots + 1                               -- slots: checked in section 7
      else
        n = n + 1
        if #f.hits > 0 then
          hit = hit + 1
          local pred = chainKinds(r)
          if check(same(pred, f.hits), ("stb %s room %s spawn %d (%d.%d): predicted %s, logged %s"):format(run.run,
              f.room, f.i, f.t, f.v, fmt(pred), fmt(f.hits))) then
            ok = ok + 1
            for j = 1, #pred do
              subN = subN + 1
              if pred[j][3] == f.hits[j][3] then subOk = subOk + 1 end
            end
          end
        end
      end
    end
  end
  print(("PASS unvisited rooms (STB): %d features forecast from (code, SpawnSeed, index); %d / %d with logged drops match; subtypes %d / %d (%d slots: section 7)"):format(
    n, ok, hit, subOk, subN, slots))
end

do
  local hardOnly, normalOnly, normalOnlySeen = 0, 0, 0
  for _, run in ipairs(cases.runs) do
    for _, f in ipairs(run.fires or {}) do
      local seed = DF.next(f.seed, 35)
      local h = DF.fireplace(f.v, seed, ctxFor(run, f, { hard = true }))
      local n = DF.fireplace(f.v, seed, ctxFor(run, f, { hard = false }))
      if not n.nothing and h.nothing then
        normalOnly = normalOnly + 1
        if #f.hits > 0 then normalOnlySeen = normalOnlySeen + 1 end
      end
      if not h.nothing then hardOnly = hardOnly + 1 end
    end
  end
  check(normalOnlySeen == 0, "a fireplace dropped where only normal mode predicts a drop")
  print(("PASS fireplaces hard mode: %d drops predicted on hard; %d more only on normal, %d of them seen"):format(
    hardOnly, normalOnly, normalOnlySeen))
end

local keys = {}
for k in pairs(stats) do keys[#keys + 1] = k end
table.sort(keys)
local line = {}
for _, k in ipairs(keys) do line[#line + 1] = k .. "=" .. stats[k] end
print("INFO predicted outcomes: " .. table.concat(line, " "))

---------------------------------------------------------------------------- 5. synthetic checks
do
  -- golden poop: 5-7 coins at X1^3.. (or Counterfeit Penny on r1 % 3 == 0); fireplace and plate
  -- shares over many seeds stay near the binary's weights
  local n, coins, fires, plates = 20000, 0, 0, { ambush = 0 }
  local x = 0x1234567
  for _ = 1, n do
    x = DF.next(x, 35)
    local g = DF.poop(3, x, { trinketAvailable = function() return false end, resolve = false })
    coins = coins + #g.entries
    if not DF.fireplace(0, x, { hard = true, resolve = false }).nothing then fires = fires + 1 end
    local p = DF.rewardPlate(x, { resolve = false, stage = 1 })
    if p.ambush then plates.ambush = plates.ambush + 1 end
  end
  local avg = coins / n
  check(avg > 5.9 and avg < 6.1, ("golden poop average coins %.3f"):format(avg))
  local giga, gn = 0, 2000
  for j = 1, gn do
    local g = DF.gigaPoop(DF.next(x + j, 35), 0, { resolve = false, trinketAvailable = function() return false end })
    giga = giga + #g.entries
    -- chunks already broken are not forecast again
    check(#DF.gigaPoop(DF.next(x + j, 35), 1000, {}).entries == 0, "giga poop at State 1000")
  end
  check(math.abs(giga / gn - 6.25) < 0.25, ("giga poop average drops %.3f"):format(giga / gn))
  check(math.abs(fires / n - 0.1) < 0.01, ("hard fireplace drop share %.4f"):format(fires / n))
  check(math.abs(plates.ambush / n - 0.5) < 0.02, ("reward plate ambush share %.4f"):format(plates.ambush / n))
  print(("PASS synthetic: golden poop %.2f coins, giga poop %.2f drops, hard fireplace drop %.3f, plate ambush %.3f"):format(
    avg, giga / gn, fires / n, plates.ambush / n))
end

---------------------------------------------------------------------------- 7. slots and beggars
-- Every pickup found on a machine's DropRNG chain must be the predicted drop of its first n
-- payments (n is not logged: the smallest n that fits), optionally followed by the machine being
-- blown up. Payer items are unknown: no items, or a golden key (key master).
do
  -- known [U]: devil beggar re-entry (research note §5): the third pickup came after the players
  -- left and re-entered; it fits only with one extra Next() and the counter at 0.
  local KNOWN = { [3936974190] = 64 }
  local function chainPos(init, n)
    local pos, x = {}, init
    for k = 1, n do x = DF.next(x, 30); if pos[x] == nil then pos[x] = k end end
    return pos
  end
  local function predicted(res, pos)
    local out = {}
    for _, e in ipairs(res.entries) do
      if e.type == 5 and e.seed then out[#out + 1] = { pos[e.seed] or -1, e.variant, e.subtype } end
    end
    for _, it in ipairs(res.items) do out[#out + 1] = { pos[it.pedestalSeed] or -1, 100, -1 } end
    return out
  end
  local function fits(pred, hits)
    table.sort(pred, function(a, b) return a[1] < b[1] end)
    return same(pred, hits)
  end
  local function fit(run, f, layoutSeed, ss, i)
    local init = DF.next(layoutSeed, 35)
    local pos = chainPos(init, 600)
    local hits = {}
    for _, h in ipairs(f.hits) do if KNOWN[layoutSeed] ~= h[1] then hits[#hits + 1] = h end end
    for _, payer in ipairs({ {}, { goldenKey = true } }) do
      local ctx = ctxFor(run, f); ctx.difficulty = 1; ctx.payer = payer
      local r = DF.slot(f.v, init, ctx, 60)
      if r.unsupported then return nil, r.unsupported end
      if ss and i then   -- the unvisited-room path gives the same payments
        local r2 = DF.forLayout(6, f.v, ss, i, (function() ctx.slotPayments = 60; return ctx end)())
        check(#r2.payments == #r.payments, ("slot forLayout %s seed %d"):format(run.run, layoutSeed))
      end
      for _, blowUp in ipairs({ false, true }) do     -- fits without an explosion first
        local pred, state = {}, init
        for n = 0, #r.payments do
          if n > 0 then
            for _, p in ipairs(predicted(r.payments[n], pos)) do pred[#pred + 1] = p end
            state = r.payments[n].state
          end
          local copy = {}
          for j, p in ipairs(pred) do copy[j] = p end
          if blowUp then
            local b = DF.slotExplode(f.v, state, ctx)
            if b.unsupported then copy = nil
            else for _, p in ipairs(predicted(b, pos)) do copy[#copy + 1] = p end end
          end
          if copy and fits(copy, hits) then return n, payer.goldenKey and "golden key" or "", blowUp, hits, copy end
        end
      end
    end
    return nil
  end
  local machines, ok, picks, subOk, subN = 0, 0, 0, 0, 0
  for _, run in ipairs(cases.runs) do
    local list = {}
    for _, f in ipairs(run.slots or {}) do list[#list + 1] = { f, f.seed, f.ss, nil } end
    for _, f in ipairs(run.stb or {}) do
      if f.t == 6 then
        -- the loader's replacement of locked kinds (rotten beggar -> key master)
        local v = DF.slotVariant(f.v, { unlocked = unlocked })
        if f.rv >= 0 then
          count("slot variants")
          if check(v == f.rv, ("slot variant %s room %s: STB 6.%d spawns as 6.%d, predicted 6.%d"):format(run.run, f.room, f.v, f.rv, v)) and v ~= f.v then
            count("slot replacements")
          end
        end
        local g = {}
        for k2, x in pairs(f) do g[k2] = x end
        g.v = v
        list[#list + 1] = { g, DF.layoutSeed(f.ss, f.i), f.ss, f.i }
      end
    end
    for _, it in ipairs(list) do
      local f, seed, ss, i = it[1], it[2], it[3], it[4]
      if i == nil and ss then i = spawnIndex(ss, seed) end
      if #f.hits > 0 then
        machines = machines + 1
        local n, payer, blown, hits, pred = fit(run, f, seed, ss, i)
        if check(n ~= nil, ("slot %s 6.%d seed %d: no payment count fits %s"):format(run.run, f.v, seed, fmt(f.hits))) then
          ok = ok + 1
          picks = picks + #hits
          for j = 1, #hits do
            if pred[j][3] ~= -1 and hits[j][2] ~= 300 and hits[j][2] ~= 70 and hits[j][2] ~= 350 then
              subN = subN + 1
              if pred[j][3] == hits[j][3] then subOk = subOk + 1 end
            end
          end
          print(("  slot %s 6.%d seed %d: %d payment(s)%s%s fit %s%s"):format(run.run, f.v, seed, n,
            payer ~= "" and (" with " .. payer) or "", blown and ", then blown up" or "", fmt(hits),
            KNOWN[seed] and (" (k" .. KNOWN[seed] .. " after re-entry: unexplained)") or ""))
        end
      end
    end
  end
  print(("PASS slots: %d / %d machines with pickups on their DropRNG chain fit a payment count (%d pickups; 1 re-entry pickup unexplained); subtypes %d / %d; STB slot variants %d / %d (%d replaced)"):format(
    ok, machines, picks, subOk, subN, stats["slot variants"] or 0, stats["slot variants"] or 0, stats["slot replacements"] or 0))
  -- payout shares on hard: the first prize of a fresh beggar comes on payment 6-8
  local first = {}
  local x = 0x2468ace
  for _ = 1, 3000 do
    x = DF.next(x, 35)
    local r = DF.slot(4, x, { difficulty = 1, resolve = false }, 12)
    first[r.firstPrize or 0] = (first[r.firstPrize or 0] or 0) + 1
  end
  check((first[6] or 0) + (first[7] or 0) + (first[8] or 0) == 3000, "beggar first prize on hard not on payment 6-8")
  print(("PASS beggar on hard: first prize on payment 6 / 7 / 8 = %d / %d / %d of 3000"):format(first[6] or 0, first[7] or 0, first[8] or 0))
end

---------------------------------------------------------------------------- 6. readContext purity
do
  -- a mock game: any call that is not a pure getter raises
  local function rng(seed)
    return setmetatable({ GetSeed = function() return seed end }, { __index = function(_, k)
      error("RNG:" .. k .. " called") end })
  end
  local players = {
    { Variant = 0, type = 4, tr = { [2] = 1, [22] = 2 }, co = { [236] = true }, seed = 111 },
    { Variant = 0, type = 30, tr = { [22] = 1, [91] = 3 }, co = {}, seed = 222 },
    { Variant = 1, type = 0, tr = { [2] = 1 }, co = {}, seed = 333 },     -- a co-op baby: ignored
  }
  for _, p in ipairs(players) do
    p.GetPlayerType = function(self) return self.type end
    p.HasTrinket = function(self, t) return (self.tr[t] or 0) > 0 end
    p.GetTrinketMultiplier = function(self, t) return self.tr[t] or 0 end
    p.HasCollectible = function(self, c) return self.co[c] == true end
    p.GetTrinketRNG = function(self, t) return rng(self.seed + t) end
    p.GetCollectibleRNG = function(self, c) return rng(self.seed + c) end
  end
  _G.Isaac = { GetPlayer = function(i) return players[i + 1] end }
  local game = { Difficulty = 1,
    GetLevel = function() return { GetStage = function() return 3 end, GetCurrentRoomIndex = function() return 5 end,
      GetStartingRoomIndex = function() return 84 end } end,
    IsGreedMode = function() return false end, GetRoom = function() return { GetType = function() return 1 end } end,
    GetNumPlayers = function() return #players end }
  local ok, ctx = pcall(DF.readContext, game, {})
  check(ok, "readContext: " .. tostring(ctx))
  if ok then
    check(ctx.trinkets[2] == 1 and ctx.trinkets[22] == 3 and ctx.trinkets[91] == 3, "readContext trinket multipliers")
    check(#ctx.holders[22] == 2 and ctx.holders[22][1] == 133 and ctx.holders[22][2] == 244, "readContext Daemon's Tail holders")
    check(#ctx.holders[236] == 1 and ctx.holders[236][1] == 347, "readContext E. Coli holder")
    check(ctx.hard == true and ctx.stage == 3, "readContext hard mode / stage")
    local r = DF.poop(0, 0x9534dc59, ctx)
    check(r ~= nil and r.rng == "poop X1", "poop with holders")
    print("PASS readContext: pure getters only; multipliers, holder RNG seeds, hard mode")
  end
  _G.Isaac = nil
end

if fails > 0 then print(("FAILED %d checks"):format(fails)); os.exit(1) end
print("PASS drop_forecast_regression")
