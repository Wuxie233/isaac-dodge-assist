# Offline item-pool emulation (Repentance+ v1.9.7.17.J460)

Goal: predict the collectible on a pedestal in a room the player has not entered yet, with a pure emulation that never calls `ItemPool:GetCollectible` (which writes game state). Vanilla game, no REPENTOGON. Researched 2026-11-05 against the user's install and 58 run logs.

Labels as in [api-map-items.md](api-map-items.md): **[C]** confirmed in the game binary or data, **[C-log]** confirmed on our run logs, **[U]** inferred or untested.

## Verdict

Feasible. The emulator reproduces **124 of 126** logged pool picks (98.4%): **36/36 treasure-room pedestals**, 24/24 first boss rewards, 22/23 shop slots, 22/23 devil deals, and every angel, curse, library, crawlspace, Boss Rush and boss-challenge pedestal (§3). The two misses have known causes. The 4 Horsemen drops are fixed items, not pool picks.

The algorithm was read from `isaac-ng.exe` (§1) rather than guessed, and the pool shuffle was checked against a saved `rep+gamestate1.dat`. Three details are essential:

- The pick seed is `X35(InitSeed)`, not `InitSeed`.
- Achievement-locked items are skipped inside the pick.
- The pool's total weight is a float32 sum taken **in XML order**.

The third detail matters because every repick multiplies rounding error by roughly 400. Summing in shuffled order dropped treasure accuracy to 31/36.

The Lua 5.3 port (`item_emulator.lua`) gives exactly the Python reference's prediction on all 130 logged cases and on 300 random stress cases. It also predicts whole multi-pedestal rooms before entry: 23/25 were fully right.

## 1. How the game picks a pedestal item

Notation: `Xn(s)` is one xorshift `RNG:Next()` with shift index `n` (api-map-items.md §0), and `Xn^k` is k steps.

### 1.1 Seeds

| Pedestal | Pick seed P | Status |
|---|---|---|
| Layout spawn i (0-based index in `Data.Spawns`) of a room, entity 5.100.0 or 5.150.x | `InitSeed = X35(X11^(i+1)(SpawnSeed))`; `P = X35(InitSeed)` | [C] `Entity_Pickup::Init` @0x6e02f0 builds `RNG(InitSeed, 35)`. For variant 100 with subtype 0 it calls `GetSeededCollectible(rng:Next())`; variant 150 calls `Room::GetShopItem(…, rng:Next())`. [C-log] 100/102 layout pedestals; `k = i+1` holds for 267 first-visit pickups checked against the extracted STB layouts. |
| First boss-room clear reward | `P = X35(AwardSeed)`, `AwardSeed = X12(SpawnSeed)` | [C-log] 24/24 (ESF `generator_dz_exp_long.cpp` uses the same seed). The pedestal's InitSeed is `X35^3(AwardSeed)`, which explains the "k=3" in api-map-items.md §3.2. In Mom's room (boss 6) it was `X35^2(AwardSeed)` (one logged room). |
| Co-op boss room, the second person's item (spawned once the first is taken), boss pool | `P = X30(InitSeed of the first boss pedestal)` | [C-log] 7/7 rooms of the 2026-11-05 Online run TTA8C7DH, Mom's room included. With the game's start seed and the save's locked items, `Emu:predictRoom` gives Squeezy then Supper for the Haunt's room 5.5011, as logged. The third and fourth person's items are not traced. |

This corrects api-map-items.md §3.3, which assumed the pick seed is `InitSeed`. With `InitSeed` as the seed, 0 of 36 treasure rooms matched.

### 1.2 Which pool

`Room::GetItemPool` @0x7ebe20 calls `ItemPool::GetPoolForRoom` @0x732dc0, which reads a fixed table at `ItemPool+0x69c` that is filled at 0x6f1366.

| Room type | Pool |
|---|---|
| 1 default, 6, 9, 13, 21, … (table −1) | treasure. `GetSeededCollectible` @0x7ec0a0 falls back to pool 0 |
| 2 shop, 22 black market | shop (1) |
| 4 treasure | treasure (0); devil (3) if `FLAG_DEVIL_TREASURE` (bit 11) |
| 5 boss | boss (2). The boss branch also reads the boss config. The Fallen (boss room `Data.Subtype` 23, rooms 5.35xx) rewards from **devil** [C-log 2/2]. Boss room subtype = boss id (STB). |
| 7 secret, 8 super secret | secret (5) |
| 10 curse | curse (12) |
| 11 challenge | treasure; **boss** when `Data.Subtype == 1` [C-log 2/2] |
| 12 library | library (6) |
| 14 devil | devil (3) |
| 15 angel | angel (4) |
| 16 crawlspace, 17 Boss Rush, 18, 19 | treasure (0) [C-log Boss Rush 10/10] |
| 20 chest room | golden chest (8) |
| 24 planetarium | planetarium (26) |
| 29 ultra secret | ultra secret (24) |
| 3 I AM ERROR | a pool drawn from the seed (not modelled) |

Greed mode uses a second table at `+0x718`; it is not modelled.

Shop items (5.150) go through a **slot type** (`Room::GetShopItem` @0x814980 → @0x814a50):

- Type 8 is the room's pool, 9 boss, 10 treasure, 0xc devil, 0xd angel, 0xe secret, 0x11 shop and 0x12 baby shop. Other slot types are pickups.
- Devil rooms, black markets and devil-treasure rooms set every slot to 8 (@0x813d90), so devil deals are fully modelled.
- Normal shops mix slot types through an RNG in @0x813d90, which is not emulated. Predicting their collectibles from the shop pool is right most of the time (22/23); the one miss was a boss-pool slot.

### 1.3 Run start: pool load and shuffle

- `itempools.xml` pools map **by name** to `ItemPoolType` 0..30. The XML lists greedCurse before greedDevil and greedAngel, while the enum order is greedDevil 19, greedAngel 20, greedCurse 21. [C]
- Each `PoolItem` is {id, initialWeight, weight, decreaseBy, removeOn, isUnlocked, isSpecial}. `isUnlocked = achievementId < 0 or Unlocked(achievementId)` is fixed when the pools load (loader @0x735a30). `_totalWeight` is the float32 sum of the weights **in XML order**. [C]
- Shuffle: MT19937 seeded with `X3^63(X27^17(startSeed))`, then each pool is shuffled in enum order with `swap(v[i], v[mt() % (i+1)])` for i = n−1 … 1. This is ESF's derivation. [C] The saved `rep+gamestate1.dat` of run 2FPCEKHY holds the pool seed `X27^17(start)` = 0xcde36708 and per-pool weight arrays; all 31 match the emulated shuffle and differ for any other start seed. At run start nothing is removed.

### 1.4 GetCollectible and pick

`ItemPool::GetCollectible(pool, seed, flags, default, backupPool)` @0x733610, with flags bit0 meaning "no decrease":

1. `NO!` held by any player sets flags bit1, which bans actives and allows 20 repicks instead of 10. TMTRAINER spawns a glitched item; Chaos replaces the pool. `_lastPool` is written, then `MC_PRE_GET_COLLECTIBLE` fires. A few hard-coded challenge branches follow.
2. `rng = RNG(seed, shift 4)`. `target = f32(f32(f32(u32) · 2.3283061589829401e-10f) · totalWeight)` (`RNG::RandomFloat` @0x7e9080, then an x87 multiply that is stored as float).
3. `pick` @0x732fa0 runs entirely in SSE single precision:
   - Walk the shuffled list, accumulating `initialWeight` (`addss`). Land on the first entry whose running sum exceeds `target`.
   - Set `frac = (sum − target) / w0`.
   - Accept the entry if `1 − frac < weight / w0`, it is not removed or room-blacklisted, `ItemConfig::Item::IsAvailable(-1)` is true, and no flag bans it.
   - Otherwise set `target = total · frac` (divided by 3.37317 if it equals the total) and walk again, up to the repick limit.
   - When repicks run out: log "item pool ran out of repicks" and take the first usable entry after the landing, wrapping around.
   - With decrease set: `weight −= decreaseBy`, and below `removeOn` the weight becomes 0 and the item is marked in the global `_removedCollectibles`.
4. If the picked entry has `isUnlocked == false`, draw `rng:Next()` again and repeat, up to 20 times. Otherwise accept. With decrease set, the item is added to the room blacklist. A failed pick falls back to the backup pool (treasure in `GetSeededCollectible`) or Breakfast.
5. Morphs: The Bible when the pool's `_bibleUpgrade` > 0, Magic Skin, Rosary Bead (trinket 7) and a challenge-specific swap. `MC_POST_GET_COLLECTIBLE` fires last.

Because each repick maps `target → total · frac`, it scales any error by `total / w0` (about 400 for treasure). This user's save has 223 of 723 items locked (115 of 407 treasure items), so repicks are common. The float32 operations and the XML-order total must therefore match the binary bit for bit. [C-log] With the total summed in shuffled order, treasure fell to 31/36 and devil to 15/23.

### 1.5 Availability (`ItemConfig::Item::IsAvailable` @0x7300d0)

An item is unavailable if any of these hold:

- `hidden`;
- tag `nochallenge` in a challenge, `nodaily` in a daily, `nogreed` in Greed;
- tag `nokeeper` when a Keeper or Tainted Keeper is present;
- tag `nolostbr` (via a Lost check);
- Tainted Lost: not `offensive`, or quality < 2 and failing a 1-in-5 roll;
- Sacred Orb: quality < 2, or quality 2 and failing a 1-in-3 roll;
- golden NO! and quality 0;
- achievement locked (`PersistentGameData::Unlocked` @0x929aa0);
- during deathmatch (`Game+0x26614 ≥ 2`), an item-ban list (`DeathmatchTypeBase` vtable).

The Tainted Lost and Sacred Orb rolls use a **local** RNG seeded from a stored seed plus the item id, so they are deterministic. [C]

The Lua `ItemConfigItem:IsAvailable()` binding @0x6ef3c0 calls this function with flags −1, or −3 (skip the achievement check) when passed `true`. It is therefore a pure read that returns exactly what the pick uses. [C]

### 1.6 State that a prediction depends on

- **Pick with decrease**: lowers the entry's weight *in that pool only*; at or below `removeOn` the item is removed globally. Treasure, shop, boss, devil, angel and secret entries are removed on their first pick. Beggar, curse, library, crane-game and chest pools keep the item at reduced weight.
- **Player gains an item**: `ItemPool::RemoveCollectible` @0x733ff0 is called from @0x75f0e0, which is probably `Entity_Player::AddCollectible` **[U]**. So every owned item is removed, starting items included.
- **Room blacklist**: holds items picked with decrease in the current room. It starts empty in a new room, so items rolled earlier in the same room cannot repeat.
- **Online co-op**: a player who joins mid-run receives 5 catch-up items "from pool treasure" ([C-log] run HVMG8F81). That they are drawn through `GetCollectible` with decrease is **[U]**; either way they end up removed.

## 2. Inputs the in-game module needs

| Input | Source (all pure reads) |
|---|---|
| Start seed | `Game():GetSeeds():GetStartSeed()` |
| Pool data | `item_pool_data.lua`, generated from this version's `itempools.xml`. Regenerate after a game update. |
| Availability | `Isaac.GetItemConfig():GetCollectible(id):IsAvailable()` (§1.5). It reads the live unlock state, which in Online play can differ from the local save (§3.2). Cache per room. |
| NO! | any player `HasTrinket(TrinketType.TRINKET_NO)` → `banActives` |
| Pick history | `MC_POST_GET_COLLECTIBLE (selected, poolType, decrease, seed)`: if `decrease`, call `emu:recordPick(poolType, selected)`. The callback ends every `GetCollectible` call [C], except early TMTRAINER returns and mod overrides. That shop items, rerolls and beggars all use `GetCollectible` is **[U]**. |
| Owned items | on every new room and after pickups, call `removeCollectible(id)` for each id where any player has `GetCollectibleNum(id) > 0`. Covers starting items. |
| Room change | `MC_POST_NEW_ROOM` → `emu:newRoom()` |
| Target room | `desc.SpawnSeed`, `desc.AwardSeed`, `desc.Data.Type/Variant/Subtype`, `desc.Flags & FLAG_DEVIL_TREASURE`, and `desc.Data.Spawns` (0-based index `i` of every single-entry 5.100.0 / 5.150.x spawn) |

Recipe for an unvisited room:

```lua
local Emu  = include("item_emulator")            -- module + data: /wuxie/tmp/isaac-item-emulator/
local emu  = Emu.new(include("item_pool_data"), Game():GetSeeds():GetStartSeed())
local opts = { isAvailable = function(id) local c = Isaac.GetItemConfig():GetCollectible(id); return c ~= nil and c:IsAvailable() end,
               banActives = anyoneHasNo }
local pool = Emu.poolForRoom(desc.Data.Type, { subtype = desc.Data.Subtype,
               devilTreasure = desc.Flags & RoomDescriptor.FLAG_DEVIL_TREASURE ~= 0 })
local picks = {}
for i = 0, desc.Data.Spawns.Size - 1 do              -- spawns that hold exactly one 5.100.0 / 5.150.x entry
  if isPedestalSpawn(desc.Data.Spawns:Get(i)) then picks[#picks + 1] = { pool, Emu.layoutPickSeed(desc.SpawnSeed, i) } end
end
local items = emu:predictRoom(picks, opts)           -- applies decrease + blacklist between slots, on a copy
local reward = emu:predict(Emu.bossRewardPool(desc.Data.Subtype), Emu.bossPickSeed(desc.AwardSeed), opts)  -- boss rooms; nil pool = fixed drop
```

Every prediction holds only for the state at that moment. Recompute after each `recordPick` or `removeCollectible`. An item rolled elsewhere first changes a later room's result, and so does a repick that lands on it.

## 3. Validation

### 3.1 Method and data

- **Logs.** 58 run logs under `/wuxie/data/isaac-dodge/logs/runs/`, 13 of which contain pedestals: 4 long co-op runs and 9 short ones. All are Online lobbies with Azazel, Keeper, Lilith, Tainted Lilith and Isaac.
- **Observations.** Every first-visit pedestal initialised on the room-load frame, plus the first collectible after a boss kill.
- **State replay.** Collectible inits and `Adding collectible … from pool X` lines are replayed in order as picks or removals.
- **Unlock state.** Taken from the user's save backups: `rep+persistentgamedata1.dat` 2026-11-03 (112 of 641 achievements) plus the `unlock steam achievement` lines in earlier runs. Achievements 9 and 186 are in the 11-05 save but no log line shows them; they are placed before the last run.
- **Game data.** Pool XMLs are extracted from `afterbirthp.a`, the Rep+ content archive. `repentance.a` still holds Rep 1.7.9b data. The ESF `item_data/itempools.xml` differs from the installed file in one greedDevil entry.

### 3.2 Results

| Pick | Logged | Correct |
|---|---|---|
| Treasure room pedestal | 36 | **36** |
| Shop slot (5.150) | 23 | 22 |
| Devil deal (5.150) | 23 | 22 |
| Angel / curse / library / crawlspace | 3 / 3 / 1 / 1 | all |
| Boss Rush pedestal | 10 | 10 |
| Boss challenge room | 2 | 2 |
| First boss reward (incl. 2 The Fallen → devil pool) | 24 | 24 |
| **All pool picks** | **126** | **124 (98.4%)** |
| Horsemen drops (Famine 207, Pestilence and War 73, Conquest 181) | 4 | not pool picks |
| Whole multi-pedestal rooms predicted before entry | 25 | 23 |

The two misses:

1. **KRKRRXJT, shop 2.7, second slot.** The slot holds Wooden Spoon (27) from the **boss** pool, so it was a slot of type 9 (§1.2). Normal-shop slot types are not emulated.
2. **YSXTMCLW, devil room 14.9.** The pick chain lands on Satanic Bible (292, achievement 126, unlocked in the local save), then two locked items. The game skipped 292 and gave The Nail (83, achievement 9). That session's unlock state differed from the local save, which fits Online's shared save (`Shared save user ID = …`, "Merging eden coins" in the logs). In game, `IsAvailable()` reads the real state.

How much each input matters:

| Change to the model | Correct |
|---|---|
| Full model | 124/126 |
| No unlock data (every item available) | 86/130 |
| No run history (no removals) | 114/126 |
| Pick seed `InitSeed` instead of `X35(InitSeed)` | 0/36 treasure |
| Total weight summed in shuffled order | 108/130 |

### 3.3 Reproduce

```
cd /wuxie/tmp/isaac-item-emulator
python3 validate3.py            # reference model over all runs (per-type table)
python3 gen_tests.py            # -> test_cases.lua
lua5.3 test_item_emulator.lua   # Lua replay: 130/130 equal to Python, 124 equal to the log; seed checks; purity
python3 gen_fuzz.py && lua5.3 test_fuzz.lua         # 300 random stress cases incl. exhausted repicks: Lua == Python
```

## 4. Known gaps (skip or flag these in game)

- **Not modelled, skip the prediction**:
  - Greed mode, the I AM ERROR room.
  - Chaos (402), whose pool comes from the pool RNG.
  - TMTRAINER (721), which creates glitched items.
  - Challenges and dailies, which have hard-coded pools in `GetCollectible` and tag filters.
  - Deathmatch.
- **Morphs after the pick**:
  - The Bible: `_bibleUpgrade` cannot be read in vanilla Lua; it is 0 unless upgrades happened.
  - Magic Skin.
  - Rosary Bead (trinket 7) re-roll into The Bible.
- **Shops**: normal-shop slot types need @0x813d90 emulated. Devil rooms and black markets are fine.
- **Boss rooms**:
  - Fixed boss drops: the Horsemen, and probably other boss-specific items.
  - Thematic pools other than The Fallen, which come from the boss config field +0x30.
  - Co-op rewards after the second person's (three or four players).
- **Layout spawns with several weighted entries** where one is a collectible: the entry choice is not modelled. Only single-entry 5.100.0 / 5.150.x spawns are predicted.
- **Changes after spawn**:
  - Rerolls.
  - Glitched Crown / Tainted Isaac cycling, which makes extra picks.
  - Alt-path "?" flip items (`Entity_Pickup::TryFlip`).
  - More Options / Damocles extra pedestals, whose spawn path is not traced.
- **History breaks**:
  - Glowing Hourglass rewinds pool state.
  - Continuing a saved run, unless the module saves its own state (`Isaac.SaveModData`, keyed by start seed).
  - Other mods that return values from `MC_PRE/POST_GET_COLLECTIBLE` or `MC_POST_PICKUP_SELECTION`.
- **Unlocks mid-run**: an item unlocked during the run is `IsAvailable` but its pool flag `isUnlocked` stays false until the next run. `Emu:predict` accepts an optional `isUnlocked` for this case; by default there is no outer retry.
- **Character pools**: there are no character-specific item lists in this version. Keeper, Lost, Tainted Lost, Sacred Orb and NO! effects all go through `IsAvailable()` and `banActives`. Only Keeper occurred in the test data.

## 5. MAPCAL logger results (2026-11-05 Online session, sensor 0.24.0)

Of 37 item picks (`IAD MAPCAL GETCOL`) in rooms entered for the first time, every one has a known seed:

- layout pedestals: 20/20 equal `layoutPickSeed(SpawnSeed, i)` for a spawn index i of the room;
- boss rewards: 6/6 equal `X35(AwardSeed)`; the second person's items: 7/7 equal `X30(first pedestal InitSeed)`;
- the rest are chests (golden 8, red 9 pools) and Boss Rush wave rewards, which the forecast does not try.

The per-spawn log (`IAD MAPCAL SPAWN`) was dropped in 0.25. 0.25 logs, on entering a room, what the forecast held for it (`IAD FORECAST: room=<list index> exact=… items=<id>:<kind>,…`), to compare with the pedestals that follow.

## 6. Evidence and files

- **Binary**: `isaac-ng.exe` SHA-256 `210cade2…fb3ae4831` (copy at `/wuxie/tmp/isaac-item-emulator/bin/`). Ghidra 12.1.4 headless decompiles are in `/wuxie/tmp/isaac-item-emulator/ghidra/out/`, one file per address.
  - `ItemPool::GetCollectible` 0x733610 (RGON signature `558bec81ecac000000a1`). The RGON `pick_collectible` signature matches an unrelated function; the real pick is 0x732fa0.
  - Pool loader 0x735a30; shuffle 0x735910; `RemoveCollectible` 0x733ff0.
  - `GetPoolForRoom` 0x732dc0; `Room::GetItemPool` 0x7ebe20; `GetSeededCollectible` 0x7ec0a0.
  - `Entity_Pickup::Init` 0x6e02f0; `Room::GetShopItem` 0x814980 / 0x814a50 / 0x813d90.
  - `IsAvailable` 0x7300d0 (Lua binding 0x6ef3c0); `Unlocked` 0x929aa0.
  - RNG: `RandomFloat` 0x7e9080, `RandomInt` 0x7e9020, `Next` 0x7e90f0.
- **Game data**: `/wuxie/tmp/isaac-item-emulator/gamedata/rpp/` (itempools.xml SHA-256 `225f4e3d…c594e6e1`, items.xml, items_metadata.xml, players.xml, achievements.xml) and `gamedata/rooms/*.stb`. They were extracted with the game's ResourceExtractor from copies in `%TEMP%`; the game folder was not written. The extractor needs relative paths and `filelist.txt` in its working directory; absolute paths crash it.
- **Save data used for unlock state**: `/wuxie/tmp/isaac-item-emulator/save/`, the persistent-data backups and the current `rep+gamestate1.dat`.
- **Module**: `/wuxie/tmp/isaac-item-emulator/item_emulator.lua` (API at the top of the file), `item_pool_data.lua` (from `gen_data.py`), `test_item_emulator.lua` with `test_cases.lua` (from `gen_tests.py`), and `test_fuzz.lua` with `fuzz_cases.lua` (from `gen_fuzz.py`).
- **Python reference**: `isaacrng.py`, `emu.py` (pool load and shuffle), `emu2.py` (GetCollectible), `validate3.py` (replay), `logparse.py`, `stb.py` (room layouts), `savefile.py` (achievements).
