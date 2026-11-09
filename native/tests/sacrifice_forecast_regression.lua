-- Sacrifice room forecast: replay the logged runs through sacrifice_forecast.lua
-- (native/research/sacrifice-room.md). The cases are observations only, taken from the run logs of
-- 2026-11-04..09 by a log miner (pickups seen while the players were in each sacrifice room, the
-- spike's sprite variant from IAD GRID, angel-pool GetCollectible seeds logged right after a local
-- sacrifice, teleports and stage transitions right after one); the model lives in the module.
-- Only the local player's sacrifices are logged (IAD HIT flags=268435584): a co-op partner's are not,
-- so a pickup's sacrifice number is at least the local hits before it, not equal to it.
--  1. sprite variant: (X35(SpawnSeed) & 3) + 1 with SpawnSeed = X11^(i+1)(room SpawnSeed)
--  2. every logged pickup whose seed is on the predicted sequence (sacrifices 1-16) has the
--     predicted variant (and subtype, coins aside: Humbling Bundle turns pennies into doubles),
--     at a sacrifice number >= the local hits before it
--  3. the angel item's pick seed = the logged GetCollectible(4, seed)
--  4. a teleport right after a local sacrifice is the 6th's angel room; a stage transition is
--     the Dark Room of the 12th or later
--  5. unit cases: run B78YY60D's first sacrifice room; Sanguine Bond against EID's formula
-- Run from the project root: lua native/tests/sacrifice_forecast_regression.lua [-v]
function include(name) return dofile("mod/isaac_dodge_assist/" .. name .. ".lua") end
local SF = include("sacrifice_forecast")
local VERBOSE = arg and arg[1] == "-v"
local CASES = {
  { run = "SBAQS4X8", variant = 3, spike = 0, seed = 610870566, spikeVariant = nil, hits = 0,
    pickups = { {10, 1, 0x73ca75d7, 0} },
    getcol = {  }, after = {  } },
  { run = "GTEDT7PF", variant = 11, spike = 4, seed = 2958051765, spikeVariant = nil, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "GJSHZSRA", variant = 4, spike = 1, seed = 466450326, spikeVariant = 3, hits = 13,
    pickups = { {10, 1, 0x31276443, 0}, {50, 1, 0xa765966f, 4}, {350, 6, 0x877d0d99, 4}, {20, 1, 0x9af3ca77, 5}, {20, 1, 0x26cfc215, 5}, {20, 1, 0x80ac50ea, 5}, {50, 1, 0xe89814a5, 6}, {10, 3, 0x9389cae3, 6}, {20, 1, 0xb24ae6b6, 6}, {20, 1, 0x721c373b, 6}, {10, 3, 0x09ea3a58, 7}, {100, 238, 0xc5c8b2d7, 9}, {20, 1, 0x84559923, 10}, {20, 1, 0x0995e2c0, 10}, {20, 1, 0xa6bd7377, 10}, {20, 1, 0x499a9a7f, 10}, {20, 1, 0xc7ad27b5, 10}, {20, 1, 0x2b0d3cee, 10}, {20, 1, 0xefffec46, 10}, {20, 1, 0x980345c5, 10}, {20, 1, 0x545e094c, 10}, {20, 1, 0xb050a6a0, 10}, {20, 1, 0xe766571c, 10}, {20, 1, 0x0e7aef1d, 10}, {20, 1, 0x21b48ec5, 10}, {20, 1, 0x1cb7fed1, 10}, {20, 1, 0x4f6c3f74, 10}, {20, 1, 0x739e377d, 10}, {20, 1, 0x0074b4ad, 10}, {20, 1, 0x099330a9, 10}, {20, 1, 0xa60fa39c, 10}, {20, 1, 0x54063292, 10}, {20, 1, 0xbea0476f, 10}, {20, 1, 0xdffce427, 10}, {20, 1, 0xb05046be, 10}, {20, 1, 0xe774c52f, 10}, {20, 1, 0x0d1a511b, 10}, {20, 1, 0x79784479, 10}, {20, 1, 0xfd48b14c, 10}, {20, 1, 0xfe71cb64, 10}, {20, 1, 0xa86ce11b, 10}, {20, 1, 0x7708adb7, 10}, {100, 239, 0x8e31c024, 11} },
    getcol = {  }, after = { {13, "stage"} } },
  { run = "KRKRRXJT", variant = 7, spike = 4, seed = 1045170484, spikeVariant = 1, hits = 1,
    pickups = { {20, 2, 0x99c7d360, 0}, {20, 1, 0x31a58a4c, 0}, {20, 1, 0x73672482, 0}, {20, 1, 0xa1f7898e, 0}, {50, 1, 0xf7e8a8ca, 0}, {10, 2, 0xe65276a1, 0}, {20, 2, 0x3027315f, 0}, {20, 1, 0xaa0f051d, 0}, {20, 1, 0xb7fa967d, 0}, {20, 1, 0x6cfc78bc, 0}, {20, 1, 0x0acad9fb, 0}, {50, 1, 0x11810212, 0}, {40, 1, 0x44af12dc, 0}, {20, 1, 0x84c94597, 0}, {100, 567, 0x6c3ae41e, 0}, {20, 1, 0x1845139b, 0}, {100, 238, 0xbf12c609, 0}, {20, 1, 0xae48bdbe, 0}, {20, 1, 0xd4f095df, 0}, {20, 1, 0x6f9334c2, 0}, {20, 1, 0x530f70a2, 0}, {20, 1, 0x2b91d3e1, 0}, {20, 1, 0xf57e669e, 0}, {20, 1, 0x77ebe10c, 0}, {20, 1, 0xcfdc3931, 0}, {20, 1, 0xae768547, 0}, {20, 1, 0xd0f5217a, 0}, {20, 1, 0xa9799c08, 0}, {20, 1, 0x456f1b21, 0}, {20, 1, 0x9cca5308, 0}, {20, 1, 0x87403be4, 0}, {20, 1, 0x58e4efca, 0}, {20, 1, 0xe6458107, 0}, {20, 1, 0x398f7635, 0}, {20, 1, 0x8c517945, 0}, {20, 1, 0x854169af, 0}, {20, 1, 0x3bda7503, 0}, {20, 1, 0xe0dea3d9, 0}, {20, 1, 0x868fa444, 0}, {20, 1, 0x7cc6b53e, 0}, {20, 1, 0x16181942, 0}, {20, 1, 0xbf96be71, 0}, {20, 1, 0xebe1d515, 0}, {20, 1, 0x5c36c7f9, 0}, {20, 1, 0x37992256, 0}, {20, 1, 0xa6e3c801, 0}, {20, 1, 0x47d7a4db, 0} },
    getcol = {  }, after = { {1, "stage"} } },
  { run = "SSDWDWF7", variant = 0, spike = 0, seed = 2557169591, spikeVariant = 2, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "8N8EGDQN", variant = 6, spike = 7, seed = 3157798712, spikeVariant = nil, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "HVMG8F81", variant = 3, spike = 0, seed = 3549933630, spikeVariant = 3, hits = 0,
    pickups = { {10, 2, 0x4a2671fd, 0}, {20, 1, 0x6c5b535f, 0}, {50, 1, 0x3f578a5a, 0}, {40, 1, 0xbab0bdef, 0}, {10, 1, 0xe889d9d3, 0}, {10, 1, 0xf6600516, 0}, {10, 3, 0xed6354fb, 0}, {100, 239, 0x954d98cc, 0}, {10, 3, 0xd4f3dccd, 0}, {10, 3, 0x6fcc6a32, 0}, {10, 3, 0x5d61b1e7, 0}, {10, 3, 0x09fc4aab, 0}, {10, 3, 0xad4f8597, 0}, {10, 3, 0x86e0bc00, 0}, {10, 3, 0x778cacf1, 0} },
    getcol = {  }, after = {  } },
  { run = "HVMG8F81", variant = 5, spike = 12, seed = 2040357863, spikeVariant = 3, hits = 0,
    pickups = { {10, 1, 0xedad2ee7, 0}, {20, 1, 0x3073a985, 0}, {10, 1, 0x83ece507, 0}, {10, 3, 0x461d2798, 0}, {20, 1, 0x483affa3, 0}, {20, 1, 0xe8d79328, 0}, {20, 1, 0x0b370c5a, 0}, {20, 1, 0xdb3ddff0, 0}, {20, 1, 0x62c53d50, 0}, {20, 1, 0x2753d812, 0}, {20, 1, 0xabbca20c, 0}, {20, 1, 0x323c940d, 0}, {20, 1, 0x4f791684, 0}, {20, 1, 0x70762b08, 0}, {20, 1, 0x41eae731, 0}, {20, 1, 0x42ed09d4, 0}, {20, 1, 0x10ea28e3, 0}, {20, 1, 0x0b78afbd, 0}, {20, 1, 0xd65beec8, 0}, {20, 1, 0x13b52e5a, 0}, {20, 1, 0x57989d64, 0}, {20, 1, 0xf6ceb7cf, 0}, {20, 1, 0x38946e3a, 0}, {20, 1, 0xbf156a25, 0}, {20, 1, 0xf36427bb, 0}, {20, 1, 0xd010a2a4, 0}, {20, 1, 0xbb069a56, 0}, {20, 1, 0x363f3e1a, 0}, {20, 1, 0x893492d1, 0}, {20, 1, 0x7875a397, 0}, {20, 1, 0xcda12068, 0}, {20, 1, 0xc547a374, 0}, {20, 1, 0x5b6a2063, 0}, {20, 1, 0xad392fb5, 0} },
    getcol = {  }, after = {  } },
  { run = "L63JA3YH", variant = 7, spike = 4, seed = 3148331738, spikeVariant = 4, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "JACABWKA", variant = 6, spike = 7, seed = 3705704390, spikeVariant = nil, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "7J0G1PZ3", variant = 0, spike = 0, seed = 759208271, spikeVariant = 2, hits = 2,
    pickups = { {20, 1, 0xba9c0c8e, 1}, {20, 1, 0x0280d7c8, 2} },
    getcol = {  }, after = {  } },
  { run = "TTA8C7DH", variant = 2, spike = 5, seed = 3706979184, spikeVariant = 4, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "4CD9937B", variant = 6, spike = 7, seed = 1119029933, spikeVariant = 4, hits = 2,
    pickups = { {20, 1, 0xfd9fa2c7, 1}, {20, 1, 0x8926ae12, 2} },
    getcol = {  }, after = {  } },
  { run = "7VY63DVL", variant = 2, spike = 5, seed = 3264518367, spikeVariant = nil, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "68SJZ6CC", variant = 2, spike = 5, seed = 3217670000, spikeVariant = 1, hits = 0,
    pickups = { {20, 1, 0xf5499eb0, 0}, {50, 1, 0xda69a480, 0}, {20, 1, 0xc7e616d5, 0}, {20, 1, 0x26b6ae89, 0}, {20, 1, 0x8852d167, 0}, {20, 1, 0x02c4470f, 0}, {10, 1, 0xb3665175, 0}, {50, 1, 0xa9e3d5ba, 0}, {40, 1, 0x66d0c48e, 0}, {40, 1, 0x7b3286d3, 0}, {10, 3, 0xd54ed9eb, 0}, {300, 6, 0x7c7a9109, 0}, {300, 7, 0x8b209e77, 0} },
    getcol = {  }, after = {  } },
  { run = "NRD1QD3T", variant = 1, spike = 2, seed = 1956323372, spikeVariant = nil, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "34RQAHAN", variant = 12, spike = 9, seed = 1804197356, spikeVariant = 3, hits = 0,
    pickups = { {10, 2, 0xf2233fbe, 0}, {10, 2, 0x63372675, 0}, {20, 1, 0xf9558ecf, 0} },
    getcol = {  }, after = {  } },
  { run = "84C0BJH9", variant = 7, spike = 4, seed = 574522284, spikeVariant = 2, hits = 0,
    pickups = { {20, 1, 0x4ae1e100, 0}, {50, 1, 0x385af6a3, 0}, {30, 1, 0xb075cf2a, 0}, {30, 1, 0x51aa8380, 0}, {30, 1, 0x0f32e9e7, 0} },
    getcol = {  }, after = {  } },
  { run = "84C0BJH9", variant = 11, spike = 4, seed = 3926714147, spikeVariant = 1, hits = 6,
    pickups = { {20, 1, 0xbe72fd05, 0}, {69, 1, 0xddef71e9, 0}, {20, 2, 0x580e8214, 0}, {20, 1, 0x326a9e13, 0}, {20, 1, 0x8e287048, 0}, {100, 528, 0xc4a124e1, 3}, {100, 657, 0xc4a124e1, 3}, {300, 8, 0xa50098b9, 5}, {20, 1, 0xceb565c3, 6}, {20, 1, 0x941521e0, 6}, {20, 1, 0x1de990ad, 6}, {20, 1, 0x70b6498d, 6}, {20, 1, 0x5540ce83, 6}, {20, 1, 0x83f581fc, 6}, {20, 1, 0x83e7713e, 6}, {20, 1, 0x808ded90, 6}, {20, 1, 0xd9a86b6d, 6}, {20, 1, 0x1af786e5, 6}, {20, 1, 0xe604ebb7, 6}, {20, 1, 0x35d55556, 6}, {20, 1, 0xc8c01945, 6}, {20, 1, 0x38a2ae13, 6}, {20, 1, 0xba8ccd0b, 6}, {20, 1, 0x1e9fd99d, 6}, {20, 1, 0x2bd69a49, 6}, {20, 1, 0xf98725fd, 6}, {20, 1, 0x2dd252d9, 6}, {20, 1, 0x5c54069f, 6}, {20, 1, 0x3dbeb867, 6}, {20, 1, 0x4f5d673f, 6}, {20, 1, 0x76894e71, 6}, {20, 1, 0xf470dee7, 6}, {20, 1, 0x475e8bff, 6}, {20, 1, 0xfac81159, 6}, {20, 1, 0x722f2910, 6}, {20, 1, 0x2c2f0b1d, 6}, {20, 1, 0x7d295356, 6}, {20, 1, 0x3402a3dd, 6}, {69, 1, 0x308cf91d, 6}, {20, 1, 0x04257978, 6}, {20, 1, 0x693c08d9, 6} },
    getcol = { {4, 2026335145}, {0, 1176510065} }, after = { {2, "teleport"} } },
  { run = "B78YY60D", variant = 7, spike = 4, seed = 2010686784, spikeVariant = nil, hits = 0,
    pickups = {  },
    getcol = {  }, after = {  } },
  { run = "B78YY60D", variant = 4, spike = 1, seed = 3222472336, spikeVariant = 4, hits = 5,
    pickups = { {20, 1, 0x81c6b837, 0}, {20, 1, 0x41282042, 0}, {10, 1, 0xb181915b, 1}, {50, 1, 0x7e2fe913, 1}, {20, 1, 0x44095bef, 2}, {20, 1, 0xa7b321ee, 2}, {20, 1, 0x793c9d1e, 2}, {40, 1, 0xba49d9b5, 2}, {10, 4, 0xd6170b57, 2}, {50, 1, 0x189f10c6, 3}, {40, 1, 0x788cc450, 3}, {20, 1, 0x2f6b6612, 3}, {100, 601, 0xe55027d4, 4}, {100, 238, 0xe25ce0b3, 4}, {20, 1, 0x69a91674, 5}, {20, 1, 0xf2ce2ad7, 5}, {20, 1, 0xfe8ed7ed, 5}, {20, 1, 0xb8fe2864, 5}, {20, 1, 0x74a6b802, 5}, {20, 1, 0x9049766a, 5}, {20, 1, 0xd5d47c05, 5}, {20, 1, 0x58f609f9, 5}, {20, 1, 0xe52cb100, 5}, {20, 1, 0x60e7d59c, 5}, {20, 1, 0x4213dd50, 5}, {20, 1, 0x005c4cf3, 5}, {20, 1, 0x0e3f3a0d, 5}, {20, 1, 0x2d3443cd, 5}, {20, 1, 0x4e622e87, 5}, {20, 1, 0x43340922, 5}, {20, 1, 0x376fbd3e, 5}, {20, 1, 0xb7d4017b, 5}, {20, 1, 0x6bfe3479, 5}, {20, 1, 0x9e24f521, 5}, {20, 1, 0xf7e7676d, 5}, {20, 1, 0x0e8e4e6a, 5}, {20, 1, 0x30e444a3, 5}, {20, 1, 0x3a5abff9, 5}, {20, 1, 0xc98bf994, 5}, {20, 1, 0x048eae0f, 5}, {20, 1, 0xdff6c3f6, 5}, {20, 1, 0xb1b9f59a, 5}, {20, 1, 0xc5c4fd0f, 5}, {20, 1, 0x43f6faf6, 5} },
    getcol = { {4, 1761525473} }, after = {  } },
  { run = "B78YY60D", variant = 5, spike = 12, seed = 1415890927, spikeVariant = 1, hits = 9,
    pickups = { {20, 4, 0x66b457d9, 1}, {20, 1, 0xa77aeae9, 1}, {40, 2, 0xabf12236, 2}, {20, 4, 0x40b64c39, 2}, {20, 1, 0x2505d0c4, 2}, {20, 4, 0xd22c5ee3, 3}, {40, 1, 0x28439efa, 4}, {20, 4, 0x6295634c, 4}, {50, 1, 0x5f1eba46, 4}, {40, 1, 0x2f2fe67f, 4}, {20, 4, 0xbec46262, 4}, {20, 4, 0x1c690850, 4}, {20, 4, 0xf0d32614, 4}, {20, 4, 0xe7412298, 5}, {20, 1, 0x768dc2b5, 6}, {20, 4, 0x066c2d79, 6}, {50, 1, 0x0171d86e, 6}, {40, 2, 0xc64c2a71, 6}, {20, 1, 0x26d78087, 6}, {10, 6, 0xf4991d38, 7}, {20, 4, 0x4a4d0887, 7}, {100, 72, 0x14b1f725, 7}, {30, 1, 0x1eade718, 8}, {20, 4, 0x70e16f0d, 8}, {20, 1, 0xf4778081, 9}, {20, 4, 0x5b1a6ce8, 9}, {100, 239, 0x44f393ec, 9}, {20, 1, 0xa13eb37d, 9}, {20, 1, 0xc59caa10, 9}, {20, 4, 0x4d0d15b9, 9}, {20, 4, 0x1af8709a, 9}, {20, 4, 0xe70d4ed6, 9}, {20, 1, 0x05f6dea3, 9}, {20, 1, 0xe6bb9365, 9}, {20, 4, 0x292d0512, 9}, {20, 4, 0x8acb65a2, 9}, {20, 4, 0x3a743e5d, 9}, {20, 4, 0xce8a16c2, 9}, {20, 1, 0x902cbbc6, 9}, {20, 4, 0xdf663969, 9}, {20, 1, 0xaa718b33, 9}, {20, 1, 0x16609926, 9}, {20, 4, 0xb74a75fc, 9}, {20, 1, 0x7106a162, 9}, {20, 1, 0x793bc494, 9}, {20, 1, 0xf162e332, 9}, {20, 1, 0xb3a1d1bf, 9}, {20, 4, 0xa45601ea, 9}, {20, 4, 0x39dd25c4, 9}, {20, 4, 0x8345438e, 9}, {20, 1, 0x9e1bb8aa, 9}, {20, 1, 0xf3dae564, 9}, {20, 4, 0xccc5748e, 9}, {20, 4, 0xfe5e0822, 9}, {20, 1, 0xaf509fb9, 9}, {20, 1, 0xe7e2c039, 9}, {20, 1, 0x1667a649, 9} },
    getcol = { {4, 3284697646} }, after = {  } },
}


local fails = 0
local function check(cond, msg)
  if not cond then fails = fails + 1; print("FAIL " .. msg) end
  return cond
end

-- 1. sprite variants
local variants, variantsOk = 0, 0
for _, c in ipairs(CASES) do
  if c.spikeVariant then
    variants = variants + 1
    local got = SF.spriteVariant(SF.layoutSeed(c.seed, c.spike))
    if check(got == c.spikeVariant, string.format("%s 13.%d sprite variant %d, predicted %d", c.run, c.variant, c.spikeVariant, got)) then
      variantsOk = variantsOk + 1
    end
  end
end

-- 2-4. predicted sequences against the logs
local ctx = { resolve = false }          -- devil deals unknown: the 7th's soul heart may be Redemption
local matched, rooms, kinds, picks, events = 0, 0, {}, 0, 0
for _, c in ipairs(CASES) do
  local seq = SF.forLayout(c.seed, c.spike, ctx, 16)
  local bySeed = {}
  for _, o in ipairs(seq) do
    for _, s in ipairs(o.spawns) do if s[1] == 5 then bySeed[s[4]] = { o = o, s = s } end end
  end
  local any = false
  for _, p in ipairs(c.pickups) do
    local hit = bySeed[p[3]]
    if hit then
      any = true
      matched = matched + 1
      local o, s = hit.o, hit.s
      local okVariant = (s[2] == p[1]) or (o.kind == "soulHeart" and o.orRedemption and p[1] == 100 and p[2] == 673)
      local okSub = s[3] < 0 or p[1] == 20 or s[2] == 50 or s[3] == p[2]
      check(okVariant and okSub, string.format("%s 13.%d sacrifice %d (%s): logged 5.%d.%d %08x", c.run, c.variant, o.n, o.desc, p[1], p[2], p[3]))
      check(o.n >= p[4], string.format("%s 13.%d pickup %08x at sacrifice %d after %d local ones", c.run, c.variant, p[3], o.n, p[4]))
      kinds[o.kind] = (kinds[o.kind] or 0) + 1
      if VERBOSE then print(string.format("  %s 13.%d #%d %s 5.%d.%d %08x", c.run, c.variant, o.n, o.desc, p[1], p[2], p[3])) end
    end
  end
  if any then rooms = rooms + 1 end
  for _, g in ipairs(c.getcol) do
    if g[1] == SF.ANGEL_POOL then
      local found = false
      for _, o in ipairs(seq) do if o.item and o.item.pickSeed == g[2] then found = true end end
      if check(found, string.format("%s 13.%d GetCollectible(4, %d) not an angel item pick", c.run, c.variant, g[2])) then picks = picks + 1 end
    end
  end
  for _, a in ipairs(c.after) do
    events = events + 1
    if a[2] == "teleport" then
      check(seq[6].kind == "angelTeleport", string.format("%s 13.%d teleport but the 6th is %s", c.run, c.variant, seq[6].desc))
    else
      local first
      for n = 12, 16 do if seq[n].kind == "darkRoom" then first = n; break end end
      check(first ~= nil, string.format("%s 13.%d stage transition without a Dark Room roll", c.run, c.variant))
    end
  end
end
check(matched >= 230 and rooms >= 12, string.format("matched pickups %d in %d rooms", matched, rooms))
check(picks >= 3, "angel item picks " .. picks)

-- 5. unit cases
local b = SF.forLayout(3222472336, 1, { resolve = false, devilDeals = 0 }, 8)
check(b[1].kind == "penny" and b[1].spawns[1][4] == 0x81c6b837, "B78YY60D 13.4 1st")
check(b[2].kind == "penny" and b[2].spawns[1][4] == 0x41282042, "B78YY60D 13.4 2nd")
check(b[3].kind == "angelChance" and b[3].angelChance == 0.15, "B78YY60D 13.4 3rd")
check(b[4].kind == "chest" and b[4].chest.seed == 0x7e2fe913, "B78YY60D 13.4 4th")
check(b[5].kind == "coins" and #b[5].spawns == 3, "B78YY60D 13.4 5th")
check(b[7].kind == "angelItem" and b[7].item.pickSeed == 1761525473 and b[7].item.spawnSeed == 0xe55027d4, "B78YY60D 13.4 7th")
check(b[8].kind == "trollBombs", "B78YY60D 13.4 8th")
-- chained from the live state = from the layout: the spike after two sacrifices
local live = SF.forecast(b[2].rng, 2, { resolve = false, devilDeals = 0 }, 2)
check(live[1].n == 3 and live[1].rng == b[3].rng and live[2].kind == b[4].kind, "live chain")
check(#SF.forecast(b[2].rng, 2, { done = true }) == 0, "sacrifice done")
-- the bomb rule of the first two
local shovel = SF.forLayout(3222472336, 1, { resolve = false, shovel = true, bombs = 0 }, 2)
check(shovel[1].kind == "bomb" and shovel[1].spawns[1][2] == 40, "bomb when flag 16 and no bombs")
-- Redemption needs a devil deal before stage 7
local function seventh(ctx2)
  for _, c in ipairs(CASES) do
    local s = SF.forLayout(c.seed, c.spike, ctx2, 7)
    if s[7].kind ~= "angelItem" and (s[7].kind == "redemption" or s[7].orRedemption) then return s[7] end
  end
end
local r = seventh({ resolve = false, devilDeals = 1, stage = 3, redemptionAvailable = true })
check(r and r.kind == "redemption" and r.spawns[1][3] == 673, "Redemption with a deal")
r = seventh({ resolve = false, devilDeals = 1, stage = 7, redemptionAvailable = true })
check(r == nil, "no Redemption from stage 7")
-- Dark Room: in the Dark Room itself back to the start; none in Greed mode
local function twelfth(ctx2)
  for _, c in ipairs(CASES) do
    local s = SF.forLayout(c.seed, c.spike, ctx2, 12)
    if s[12].kind == "darkRoom" then return s[12] end
  end
end
check(twelfth({ resolve = false }).teleport == "darkroom", "Dark Room teleport")
check(twelfth({ resolve = false, stage = 11, stageType = 0 }).teleport == "start", "Dark Room: back to its start")
check(twelfth({ resolve = false, greed = true }) == nil, "no Dark Room in Greed mode")
-- Sanguine Bond: EID's formula (one X35 then one (1,5,19) step, seed * 2^-32)
local band = { 0.15, 0.48, 0.58, 0.63, 0.65 }
local names = { "coins", "damage", "blackHearts", "item", "leviathan" }
local seed = 0x12345678
for _ = 1, 200 do
  local o = SF.sanguine(seed, {})
  local e = SF.next(SF.next(seed, 35), 2) * 2.3283061589829401e-10
  local want = "nothing"
  for j, t in ipairs(band) do if e < t then want = names[j]; break end end
  if math.abs(e - o.f) < 1e-6 and math.abs(e - 0.15) > 1e-6 then check(o.kind == want, string.format("sanguine %08x: %s vs EID %s", seed, o.kind, want)) end
  seed = o.rng
end

local list = {}
for k, n in pairs(kinds) do list[#list + 1] = k .. " " .. n end
table.sort(list)
if fails > 0 then error(fails .. " sacrifice forecast checks failed") end
print(string.format("PASS sacrifice forecast: sprite variants %d/%d, %d logged pickups in %d rooms on the predicted sacrifices (%s), angel item picks %d, teleports/stage changes %d",
  variantsOk, variants, matched, rooms, table.concat(list, ", "), picks, events))
