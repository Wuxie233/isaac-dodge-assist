-- Chest forecast: replay the logged runs through chest_forecast.lua
-- (native/research/chest-contents.md). Data: native/tests/data/chest_forecast_cases.lua, made by
-- tools/gen_chest_forecast_cases.py from the logs (observations only; the model lives here).
--  1. loot: every opened chest / sack must spawn exactly the predicted pickups at the predicted
--     positions of its DropRNG chain X30^k(InitSeed) (and its pedestal / GETCOL seed), under the
--     logged context. Pickup trinkets are not logged once dropped, so the ones added earlier in
--     the run are tried as subsets ("trinket hypothesis"); nested containers and other containers
--     of the run claim their own chain positions.
--  2. rocks: every pickup found on a layout alt rock's X35(SpawnSeed) chain must be predicted.
--  3. items: chest collectibles through item_emulator.lua with the replayed pool state.
-- Run from the project root: lua native/tests/chest_forecast_regression.lua
local CF = dofile("mod/isaac_dodge_assist/chest_forecast.lua")
local Emu = dofile("mod/isaac_dodge_assist/item_emulator.lua")
local data = dofile("mod/isaac_dodge_assist/item_pool_data.lua")
local cases = dofile("native/tests/data/chest_forecast_cases.lua")

local fails = 0
local function check(cond, msg)
  if not cond then fails = fails + 1; print("FAIL " .. msg) end
end
local X = CF.next
local VERBOSE = arg and arg[1] == "-v"

local function chainMap(seed, n)
  local m, x = {}, seed
  for k = 1, n do
    x = X(x, 30)
    if m[x] == nil then m[x] = k end
  end
  return m
end
local function chainAt(seed, k)
  for _ = 1, k do seed = X(seed, 30) end
  return seed
end

local function contextFor(c, trinkets)
  return { trinkets = trinkets, stage = c.stage, roomIndex = c.room, startRoomIndex = 0, momsKey = c.mk,
    sackHead = c.sh }
end

-- predicted logged inits of one container: {k, variant} list, collectibles listed apart.
-- opens > 1: an eternal chest opened again on the same DropRNG (subtype 1).
local function expected(v, s, seed, ctx, base, opens)
  base = base or 0
  local ents, rng = CF.loot(v, s, seed, ctx)
  local off = rng.k
  for _ = 2, opens or 1 do
    local hasItem = false
    for _, e in ipairs(ents) do if e.variant == 100 and e.type == 5 then hasItem = true end end
    if #ents == 0 or hasItem then break end
    local more, r2 = CF.loot(v, 1, rng.s, ctx)
    if #more == 0 then break end
    for _, e in ipairs(more) do
      if e.k then e.k = e.k + off end
      if e.pickK then e.pickK = e.pickK + off end
      ents[#ents + 1] = e
    end
    rng = r2
    off = off + r2.k
  end
  -- chain position of each collectible's pick seed
  for _, e in ipairs(ents) do
    if e.pickSeed then
      local m = chainMap(seed, 400)
      e.pickK = m[e.pickSeed]
    end
  end
  if ctx.sackHead then ents = CF.applySackHead(ents, v) end
  local pk, items = {}, {}
  for _, e in ipairs(ents) do
    if e.type == 5 and e.variant == 100 then
      items[#items + 1] = { k = e.k and e.k + base, pickK = e.pickK and e.pickK + base, pool = e.pool,
        subtype = e.subtype }
    elseif e.type == 5 and e.k then
      pk[#pk + 1] = { e.k + base, e.variant }
      if e.sackHead and e.replacedK then pk[#pk + 1] = { e.replacedK + base, e.replaces } end
    end
  end
  return pk, items
end

local function key(k, v) return k * 1000 + v end

local function judge(c, trinkets, opens, foreign)
  local ctx = contextFor(c, trinkets)
  local pk, items = expected(c.v, c.s, c.seed, ctx, 0, opens)
  local exp, claimed, gotc = {}, {}, {}
  for _, p in ipairs(pk) do local kk = key(p[1], p[2]); exp[kk] = (exp[kk] or 0) + 1 end
  for _, n in ipairs(c.onchain) do
    local npk, nitems = expected(n[2], n[3] ~= 0 and n[3] or 1, chainAt(c.seed, n[1]), ctx, n[1], 1)
    for _, p in ipairs(npk) do local kk = key(p[1], p[2]); claimed[kk] = (claimed[kk] or 0) + 1 end
    for _, it in ipairs(nitems) do if it.k then local kk = key(it.k, 100); claimed[kk] = (claimed[kk] or 0) + 1 end end
  end
  for _, g in ipairs(c.got) do
    local kk = key(g[1], g[2])
    if not foreign[kk] then gotc[kk] = (gotc[kk] or 0) + 1 end
  end
  local why = {}
  for kk, n in pairs(exp) do
    if (gotc[kk] or 0) < n then why[#why + 1] = ("missing %d.%d"):format(kk // 1000, kk % 1000) end
  end
  for kk, n in pairs(gotc) do
    local extra = n - (exp[kk] or 0) - (claimed[kk] or 0)
    if extra > 0 then
      local isLaterItem = false
      for i = 2, #items do if items[i].k and key(items[i].k, 100) == kk then isLaterItem = true end end
      if not isLaterItem then why[#why + 1] = ("extra %d.%d"):format(kk // 1000, kk % 1000) end
    end
  end
  local getcol = {}
  for _, g in ipairs(c.getcol) do getcol[g[1]] = g[2] end
  for _, it in ipairs(items) do
    if it.pickK and next(getcol) then
      if getcol[it.pickK] == nil then why[#why + 1] = "pick seed not logged"
      elseif getcol[it.pickK] ~= it.pool then why[#why + 1] = "pool " .. getcol[it.pickK] .. "~=" .. it.pool end
    end
  end
  if #items > 0 and c.ped == nil and items[1].subtype == 0 then why[#why + 1] = "no pedestal" end
  if #items == 0 and c.ped ~= nil then why[#why + 1] = "unexpected pedestal" end
  return #why == 0, why
end

local function subsets(list)
  local out = { {} }
  for _, t in ipairs(list) do
    local n = #out
    for i = 1, n do
      local s = {}
      for _, x in ipairs(out[i]) do s[#s + 1] = x end
      s[#s + 1] = t
      out[#out + 1] = s
    end
  end
  table.sort(out, function(a, b) return #a < #b end)
  return out
end

-- 1. loot ------------------------------------------------------------------------------------
-- trinkets GetLootList reads (the data also lists subtype trinkets)
local LOOT_TRINKETS = { [22] = true, [34] = true, [36] = true, [41] = true, [42] = true, [44] = true, [45] = true,
  [76] = true, [159] = true, [61] = true }
for _, run in ipairs(cases.loot) do
  for _, c in ipairs(run.containers) do
    c.lootTr = {}
    for _, t in ipairs(c.tr) do if LOOT_TRINKETS[t] then c.lootTr[#c.lootTr + 1] = t end end
  end
end
local stats = { total = 0, ok = 0, okHyp = 0, strict = 0, strictOk = 0, bad = 0 }
local byVariant = {}
local bestCtx = {}
for _, run in ipairs(cases.loot) do
  -- foreign claims: every container's predicted entry seeds (no trinkets)
  local owners = {}
  for _, c in ipairs(run.containers) do
    local ents = CF.loot(c.v, c.s, c.seed, contextFor(c, {}))
    if c.sh then ents = CF.applySackHead(ents, c.v) end
    for _, e in ipairs(ents) do
      if e.seed then
        local o = owners[e.seed] or {}
        o[#o + 1] = { c.seed, e.variant }
        owners[e.seed] = o
        if e.sackHead and e.replacedK then end
      end
    end
  end
  for _, c in ipairs(run.containers) do
    local m = chainMap(c.seed, 160)
    local foreign = {}
    for sd, list in pairs(owners) do
      local k = m[sd]
      if k then
        for _, o in ipairs(list) do
          if o[1] ~= c.seed then foreign[key(k, o[2])] = true end
        end
      end
    end
    -- entries this container predicts itself are never foreign
    local own = CF.loot(c.v, c.s, c.seed, contextFor(c, {}))
    for _, e in ipairs(own) do if e.k then foreign[key(e.k, e.variant)] = nil end end
    local found, hyp
    for _, sub in ipairs(subsets(c.lootTr)) do
      local tr = {}
      for _, t in ipairs(sub) do tr[t] = 1 end
      for opens = 1, c.v == 53 and 11 or 1 do
        if judge(c, tr, opens, foreign) then found, hyp = tr, sub break end
      end
      if found then break end
    end
    stats.total = stats.total + 1
    local bv = byVariant[c.v] or { n = 0, ok = 0 }
    byVariant[c.v] = bv
    bv.n = bv.n + 1
    local strict = #c.lootTr == 0
    if strict then stats.strict = stats.strict + 1 end
    if found then
      bv.ok = bv.ok + 1
      if #hyp == 0 then stats.ok = stats.ok + 1 else stats.okHyp = stats.okHyp + 1 end
      if strict then stats.strictOk = stats.strictOk + 1 end
      bestCtx[c.seed] = found
    else
      stats.bad = stats.bad + 1
      if VERBOSE then
        local _, why = judge(c, {}, 1, foreign)
        print(("  miss %s %d.%d seed=%x tr={%s}: %s"):format(run.run, c.v, c.s, c.seed, table.concat(c.lootTr, ","),
          table.concat(why, ", ")))
      end
    end
  end
end
local names = { [50] = "brown", [51] = "stone", [52] = "spiked", [53] = "eternal", [54] = "mimic", [55] = "old",
  [56] = "wooden", [57] = "mega", [58] = "haunted", [60] = "golden", [360] = "red", [390] = "mom's", [69] = "sack" }
local parts = {}
local vs = {}
for v in pairs(byVariant) do vs[#vs + 1] = v end
table.sort(vs)
for _, v in ipairs(vs) do parts[#parts + 1] = ("%s %d/%d"):format(names[v] or v, byVariant[v].ok, byVariant[v].n) end
-- At generation (2026-11-06 logs): 373 of 376 opened containers; the 3 misses (run Z10KWQWM) held
-- the Error trinket, which imitates a pickup trinket that the log does not name.
check(stats.ok + stats.okHyp >= 373, "loot replay fell to " .. (stats.ok + stats.okHyp) .. "/" .. stats.total)
check(stats.strictOk >= 255, "loot replay without trinkets fell to " .. stats.strictOk .. "/" .. stats.strict)
if fails == 0 then
  print(("PASS chest forecast loot: %d/%d opened containers (%d with no pickup trinket in the run: %d/%d; %d need a trinket subset) - %s")
    :format(stats.ok + stats.okHyp, stats.total, stats.strict, stats.strictOk, stats.strict, stats.okHyp,
      table.concat(parts, ", ")))
end

-- 1b. subtypes ---------------------------------------------------------------------------------
-- Every subtype-0 pickup of a replayed container takes its subtype from RNG(InitSeed, 35) when it
-- spawns (M.resolve). Context: the save's unlocks, the run's player types and collectibles, hard
-- mode (not logged; these Online lobbies fit hard mode in every run: 6 hearts and 1 battery more
-- than normal, none fewer). Heart trinkets (Bible Tract, Mom's Pearl, Black Lipstick, Daemon's
-- Tail, Mom's Locket) are not logged while held and are left out.
do
  local before = fails
  local unlocked = {}
  for _, a in ipairs(cases.unlocked or {}) do unlocked[a] = true end
  local res = {}
  local NAMES = { [10] = "hearts", [20] = "coins", [30] = "keys", [40] = "bombs", [90] = "batteries",
    [69] = "sacks", [50] = "chests" }
  for _, run in ipairs(cases.loot) do
    local types = {}
    for _, t in ipairs(run.types or {}) do types[t] = true end
    for _, c in ipairs(run.containers) do
      local tr = bestCtx[c.seed]
      if tr and c.v ~= 53 then
        local co = {}
        for _, id in ipairs(c.co or {}) do co[id] = true end
        local ctx = contextFor(c, tr)
        ctx.collectibles, ctx.playerTypes, ctx.unlocked, ctx.hard, ctx.roomType = co, types, unlocked, true, c.rtype
        local ents = CF.loot(c.v, c.s, c.seed, ctx)
        local logged = {}
        for _, g in ipairs(c.got) do logged[g[1]] = logged[g[1]] or {}; table.insert(logged[g[1]], g) end
        for _, n in ipairs(c.onchain) do logged[n[1]] = logged[n[1]] or {}; table.insert(logged[n[1]], n) end
        for _, e in ipairs(ents) do
          local cls = e.type == 5 and e.subtype == 0 and e.k and NAMES[e.variant == 60 and 50 or e.variant]
          if cls and logged[e.k] then
            local v, s = CF.resolve(e.variant, e.seed, ctx)
            local r = res[cls] or { n = 0, ok = 0 }
            res[cls] = r
            r.n = r.n + 1
            for _, g in ipairs(logged[e.k]) do
              if g[2] == v and g[3] == s then r.ok = r.ok + 1 break end
            end
          end
        end
      end
    end
  end
  -- rock drops: the good roll's pickups spawn with chain seeds
  for _, rk in ipairs(cases.rocks) do
    if #rk.hits > 0 then
      local p = CF.rock(6, rk.backdrop, rk.seed, { roomType = rk.rtype, unlocked = unlocked, hard = true })
      if not (p.entries[1] and p.entries[1].k == rk.hits[1][1]) then
        p = CF.rock(6, rk.backdrop, rk.seed, { roomType = rk.rtype, unlocked = unlocked, hard = true,
          trinketAvailable = function() return false end })
      end
      for i, e in ipairs(p.entries) do
        local h = rk.hits[i]
        local cls = NAMES[e.variant]
        if h and cls then
          local r = res[cls] or { n = 0, ok = 0 }
          res[cls] = r
          r.n = r.n + 1
          if h[2] == e.variant and h[3] == e.subtype then r.ok = r.ok + 1 end
        end
      end
    end
  end
  local parts = {}
  for _, cls in ipairs({ "coins", "keys", "bombs", "hearts", "batteries", "sacks", "chests" }) do
    if res[cls] then parts[#parts + 1] = ("%s %d/%d"):format(cls, res[cls].ok, res[cls].n) end
  end
  -- at generation: coins 373/373, keys 118/118, bombs 193/193, hearts 97/97, batteries 5/5, chests 4/4
  for _, cls in ipairs({ "coins", "keys", "bombs", "batteries", "chests" }) do
    local r = res[cls]
    check(r and r.ok == r.n, cls .. " subtypes: " .. (r and (r.ok .. "/" .. r.n) or "none"))
  end
  check(res.hearts and res.hearts.ok >= 97, "heart subtypes fell to " .. (res.hearts and res.hearts.ok or 0))
  if fails == before then
    print("PASS chest forecast pickup subtypes from InitSeed: " .. table.concat(parts, ", "))
  end
end

-- 2. rocks -----------------------------------------------------------------------------------
do
  local seen, ok, okFallback, outcomes = 0, 0, 0, { good = 0, bad = 0, nothing = 0, trinket = 0, item = 0 }
  local before = fails
  for _, r in ipairs(cases.rocks) do
    local p = CF.rock(6, r.backdrop, r.seed, { roomType = r.rtype })
    if p.item then outcomes.item = outcomes.item + 1
    elseif p.trinket then outcomes.trinket = outcomes.trinket + 1
    elseif #p.groups > 0 then outcomes.good = outcomes.good + 1
    elseif p.bad then outcomes.bad = outcomes.bad + 1
    else outcomes.nothing = outcomes.nothing + 1 end
    if #r.hits > 0 then
      seen = seen + 1
      local function same(q)
        if #q.entries ~= #r.hits then return false end
        for i, h in ipairs(r.hits) do
          if q.entries[i].k ~= h[1] or q.entries[i].variant ~= h[2] then return false end
        end
        return true
      end
      if same(p) then ok = ok + 1
      elseif p.trinket and same(CF.rock(6, r.backdrop, r.seed, { roomType = r.rtype,
          trinketAvailable = function() return false end })) then okFallback = okFallback + 1
      else check(false, ("rock %s seed=%d backdrop=%d"):format(r.run, r.seed, r.backdrop)) end
    end
  end
  check(ok + okFallback == seen and seen >= 9, "alt rock drops: " .. (ok + okFallback) .. "/" .. seen)
  -- outcome shares over all layout alt rocks: 10% good roll, 20% bad, about 2.5% trinket, 0.5% item
  check(outcomes.good >= 20 and outcomes.good <= 50 and outcomes.bad >= 40 and outcomes.bad <= 85,
    "alt rock outcome shares look wrong")
  if fails == before then
    print(("PASS chest forecast alt rocks: %d/%d rocks with logged drops (%d via trinket not in pool); %d layout rocks: %d good, %d bad, %d nothing, %d trinket, %d item")
      :format(ok + okFallback, seen, okFallback, #cases.rocks, outcomes.good, outcomes.bad, outcomes.nothing,
        outcomes.trinket, outcomes.item))
  end
end

-- 3. items -----------------------------------------------------------------------------------
do
  local total, correct, cycles, before = 0, 0, 0, fails
  for _, run in ipairs(cases.items) do
    local emu = Emu.new(data, Emu.seedFromString(run.seed))
    local unav, notUnl = {}, {}
    for _, id in ipairs(run.unavailable) do unav[id] = true end
    for _, id in ipairs(run.notUnlocked) do notUnl[id] = true end
    local opts = { isAvailable = function(id) return not unav[id] end,
                   isUnlocked = function(id) return not notUnl[id] end }
    for _, ev in ipairs(run.events) do
      local op = ev[1]
      if op == "room" then emu:newRoom()
      elseif op == "add" then emu:removeCollectible(ev[2])
      elseif op == "remove" then emu:removeCollectible(ev[2]); emu.roomBlacklist[ev[2]] = true
      elseif op == "pick" then emu:recordPick(ev[2], ev[3])
      elseif op == "chest" then
        local v, s, seed, stage, flag, logged = ev[2], ev[3], ev[4], ev[5], ev[6], ev[8]
        local ctx = { trinkets = bestCtx[seed] or {}, stage = stage, roomIndex = flag, startRoomIndex = 0 }
        local state, sub, it = seed, s, nil
        for _ = 1, v == 53 and 8 or 1 do         -- eternal chest: the opening that gave the item
          local r = CF.predict(v, sub, state, ctx, seed)
          if not r or r.empty then break end
          if r.items[1] then it = r.items[1] break end
          state, sub = r.rngAfter, 1
        end
        if it and it.pickSeed then
          local o = opts
          if it.excludeDevilSacrifice then
            o = { isUnlocked = opts.isUnlocked, isAvailable = function(id)
              return not CF.DEVIL_SACRIFICE[id] and opts.isAvailable(id) end }
          end
          local got = emu:predict(it.pool, it.pickSeed, o)
          total = total + 1
          if got == logged then correct = correct + 1
          elseif VERBOSE then print(("  item miss %s %d seed=%x: %s ~= %s"):format(run.seed, v, seed, tostring(got), logged)) end
          emu:recordPick(it.pool, logged)
        else
          emu:removeCollectible(logged)
        end
      elseif op == "chestcycle" then
        local pool = Emu.poolForRoom(ev[2]) or 0
        local got = emu:predict(pool, CF.cycleSeed(ev[3]), opts)
        total, cycles = total + 1, cycles + 1
        if got == ev[4] then correct = correct + 1
        elseif VERBOSE then print(("  cycle miss %s: %s ~= %s"):format(run.seed, tostring(got), ev[4])) end
        emu:recordPick(pool, ev[4])
      end
    end
  end
  if #cases.items > 0 then
    -- at generation: 66 of 66 (golden, red, wooden, old, stage-11 chests, Tainted Isaac cycles)
    check(correct >= 66 and correct == total, ("chest items %d/%d"):format(correct, total))
    if fails == before then
      print(("PASS chest forecast items: %d/%d chest collectibles (%d Tainted Isaac second items) through item_emulator")
        :format(correct, total, cycles))
    end
  else
    print("SKIP chest forecast items: data generated without --emu-ref")
  end
end

-- 4. purity and API --------------------------------------------------------------------------
do
  local ctx = { trinkets = { [45] = 2 }, stage = 3 }
  local before = fails
  local a = CF.predict(60, 1, 0x0fcccd82, ctx, 0x0fcccd82)
  local b = CF.predict(60, 1, 0x0fcccd82, ctx, 0x0fcccd82)
  check(#a.entries == #b.entries and ctx.trinkets[45] == 2, "predict is pure")
  -- golden chest 0fcccd82 (run Z10KWQWM): item, GETCOL seed 2003122270 = X30^3, pedestal 604aad47 = X7
  local g = CF.predict(60, 1, 0x0fcccd82, { stage = 3 }, 0x0fcccd82)
  check(#g.items == 1 and g.items[1].pool == 8 and g.items[1].pickSeed == 2003122270
        and g.items[1].pedestalSeed == 0x604aad47, "golden chest 0fcccd82 item seed")
  check(CF.predict(60, 0, 1, {}) == nil and CF.predict(20, 1, 1, {}) == nil, "opened chest / not a container")
  check(CF.altRockKind(1) == 1 and CF.altRockKind(4) == 2 and CF.altRockKind(7) == 3 and CF.altRockKind(10) == 4
        and CF.altRockKind(31) == 5, "alt rock kinds")
  if fails == before then print("PASS chest forecast purity and seed helpers") end
end

assert(fails == 0, "chest forecast: " .. fails .. " failures")
