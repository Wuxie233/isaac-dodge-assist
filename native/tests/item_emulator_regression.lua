-- Item emulator (0.22): replay the 2026-11-04/05 logged runs through
-- item_emulator.lua. Checks (1) seed helpers against logged values, (2)
-- every logged pedestal against the Python reference prediction (must agree
-- exactly) and the logged item (124 of 126 at generation, see
-- native/research/item-emulation.md), (3) whole rooms, (4) purity.
local Emu = dofile("mod/isaac_dodge_assist/item_emulator.lua")
local data = dofile("mod/isaac_dodge_assist/item_pool_data.lua")
local cases = dofile("native/tests/data/item_emulator_cases.lua")

local fails = 0
local function check(cond, msg)
  if not cond then fails = fails + 1; print("FAIL " .. msg) end
end

-- 1. seed helpers --------------------------------------------------------------
check(Emu.seedFromString("GJSH ZSRA") == Emu.seedFromString("GJSHZSRA"), "seed string spaces")
-- treasure room 4.12 (SpawnSeed 1721222884): pedestal is spawn index 4, InitSeed 0x91ba109a (My Reflection)
check(Emu.layoutInitSeed(1721222884, 4) == 0x91ba109a, "layoutInitSeed 4.12")
-- treasure room 4.26 (one spawn, index 0) of run 8N8EGDQN: InitSeed d130f8ad
check(Emu.layoutInitSeed(3739299691, 0) == 0xd130f8ad, "layoutInitSeed 4.26")
-- stage seeds: start seed RNG (shift 27); GJSHZSRA stage 2 seed logged as 1743339107
do
  local s = Emu.seedFromString("GJSHZSRA")
  for _ = 1, 3 do s = Emu.next(s, 27) end
  check(s == 1743339107, "stage seed 2 of GJSHZSRA")
end
-- the saved rep+gamestate1.dat of run 2FPCEKHY stores the pool init seed 0xcde36708
do
  local s = Emu.seedFromString("2FPCEKHY")
  for _ = 1, 17 do s = Emu.next(s, 27) end
  check(s == 0xcde36708, "item pool init seed (2FPCEKHY)")
end

check(Emu.bossRewardPool(23) == 3 and Emu.bossRewardPool(9) == nil and Emu.bossRewardPool(1) == 2, "bossRewardPool")
check(Emu.poolForRoom(4) == 0 and Emu.poolForRoom(4, { devilTreasure = true }) == 3 and Emu.poolForRoom(11, { subtype = 1 }) == 2
      and Emu.poolForRoom(1) == 0 and Emu.poolForRoom(24) == 26, "poolForRoom")

-- 2. replay ----------------------------------------------------------------------
local total, agree, correct = 0, 0, 0
local byKind = {}
for _, run in ipairs(cases) do
  local emu = Emu.new(data, Emu.seedFromString(run.seed))
  local unav, notUnl = {}, {}
  for _, id in ipairs(run.unavailable) do unav[id] = true end
  for _, id in ipairs(run.notUnlocked) do notUnl[id] = true end
  local opts = {
    isAvailable = function(id) return not unav[id] end,
    isUnlocked = function(id) return not notUnl[id] end,
  }
  for _, ev in ipairs(run.events) do
    local op = ev[1]
    if op == "room" then emu:newRoom()
    elseif op == "add" then emu:removeCollectible(ev[2])
    elseif op == "remove" then emu:removeCollectible(ev[2]); emu.roomBlacklist[ev[2]] = true
    elseif op == "pick" then emu:recordPick(ev[2], ev[3])
    elseif op == "expect" then
      local pool, seed, logged, py, kind, label = ev[2], ev[3], ev[4], ev[5], ev[6], ev[7]
      local got = emu:predict(pool, seed, opts) or 0
      total = total + 1
      if got == py then agree = agree + 1 else check(false, ("lua %d ~= python %d at %s"):format(got, py, label)) end
      local k = byKind[kind] or { n = 0, ok = 0 }
      byKind[kind] = k
      k.n = k.n + 1
      if got == logged then correct = correct + 1; k.ok = k.ok + 1 end
    end
  end
end
-- Summary: print(("replayed %d pedestals: lua==python %d, lua==logged %d"):format(total, agree, correct))
check(agree == total, "lua and python predictions agree")
check(correct >= 124, "accuracy against the logged items fell: " .. correct)

-- 3. whole-room prediction (multi-pedestal rooms predicted before entry) ------------
do
  local rooms, roomOk = 0, 0
  for _, run in ipairs(cases) do
    local emu = Emu.new(data, Emu.seedFromString(run.seed))
    local unav, notUnl = {}, {}
    for _, id in ipairs(run.unavailable) do unav[id] = true end
    for _, id in ipairs(run.notUnlocked) do notUnl[id] = true end
    local opts = { isAvailable = function(id) return not unav[id] end,
                   isUnlocked = function(id) return not notUnl[id] end }
    local ev = run.events
    local i = 1
    while i <= #ev do
      local e = ev[i]
      if e[1] == "room" then emu:newRoom()
      elseif e[1] == "add" then emu:removeCollectible(e[2])
      elseif e[1] == "remove" then emu:removeCollectible(e[2]); emu.roomBlacklist[e[2]] = true
      elseif e[1] == "pick" then emu:recordPick(e[2], e[3])
      elseif e[1] == "expect" and e[6] == "layout" then
        -- collect this room's layout pedestals: expect, pick, expect, pick, ...
        local picks, logged, j = {}, {}, i
        while ev[j] and ev[j][1] == "expect" and ev[j][7] == e[7] and ev[j][6] == "layout" do
          picks[#picks + 1] = { ev[j][2], ev[j][3] }
          logged[#logged + 1] = ev[j][4]
          j = j + 2   -- skip the following pick event
        end
        if #picks >= 2 then
          local got = emu:predictRoom(picks, opts)
          local all = true
          for k = 1, #picks do if got[k] ~= logged[k] then all = false end end
          rooms = rooms + 1
          if all then roomOk = roomOk + 1 end
        end
      end
      i = i + 1
    end
  end
  -- print(("multi-pedestal rooms predicted before entry: %d/%d fully right"):format(roomOk, rooms))
end

-- 1b. co-op boss rooms (2026-11-05 Online run TTA8C7DH): the first reward
-- pedestal's InitSeed from the AwardSeed, and the second player's item seed
-- X30(that InitSeed). {AwardSeed, boss subtype, first InitSeed, second seed};
-- the subtype only matters for Mom (6), so the others carry 0.
for _, c in ipairs({
  {1150171659, 0, 0x3b1bcc7b, 4260989856}, {2522777397, 0, 0xcf42d670, 3724627119},
  {4088030492, 0, 0x6b0a0979, 7333545}, {2270505770, 0, 0x7237d00f, 3719408559},
  {969566351, 0, 0x4ba38a55, 936656538}, {3572268324, 6, 0xf4075797, 561915169},
}) do
  local first = Emu.bossItemInitSeed(c[1], c[2])
  check(first == c[3], ("boss pedestal InitSeed as=%d"):format(c[1]))
  check(Emu.extraBossPickSeed(first) == c[4], ("co-op boss item seed as=%d"):format(c[1]))
end
-- 1c. Void (477) co-op boss absorption divergence (2026-11-19 Duke of Flies 5.2013):
-- normal pickup uses pedestal->DropRNG (X30(0x13c9f5fa) = 2237562146), whereas Void
-- uses activating player->DropRNG (X30(167906700) = 1605593133, InitSeed = 0x880aefd2).
check(Emu.extraBossPickSeed(0x13c9f5fa) == 2237562146, "normal pickup uses pedestal->DropRNG")
check(Emu.next(167906700, 30) == 1605593133, "Void boss replacement pick seed uses player->DropRNG")
check(Emu.next(1605593133, 30) == 0x880aefd2, "Void boss replacement InitSeed uses player->DropRNG")

-- 4. purity: predict must not change state -------------------------------------
do
  local emu = Emu.new(data, Emu.seedFromString("NZ613W0S"))
  local before = emu.pools[1].w[1]
  local a = emu:predict(0, 12345)
  local b = emu:predict(0, 12345)
  check(a == b and emu.pools[1].w[1] == before and next(emu.removed) == nil, "predict is pure")
end

assert(fails == 0, "item emulator: " .. fails .. " failures")
print("PASS item emulator: seed helpers, co-op boss item seeds, 130 logged pedestals (Lua == Python reference), whole rooms, purity")
