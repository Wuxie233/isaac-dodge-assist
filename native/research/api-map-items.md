# Vanilla Lua API: floor map, room layouts, item prediction (Repentance+)

Research for a read-only assist overlay. Target: Repentance+ v1.9.7.17.J460 (the user's install, from its launch log), vanilla Lua only (no REPENTOGON), Online co-op safe. Researched 2026-11-05.

Labels: **[C]** confirmed (source or code reference given). **[C-log]** confirmed by our own analysis of the user's game logs (method in §3.2). **[U]** uncertain: inferred, secondary, or untested on this build.

Source abbreviations (full links at the end): IsaacDocs = wofsauge.github.io/IsaacDocs/rep; RGON = REPENTOGON source/docs @7212bc5; EID = External-Item-Descriptions @993c881; MMAPI = MinimapAPI @82b3134; StageAPI = BOIStageAPI15 @9057387; ISC = isaacscript @72a71fa; ESF = eden-seed-finder @f8d46aa; vanilla `main.lua` = `<game>\resources\scripts\main.lua` of the installed game.

## Key conclusions

1. The whole floor is readable from floor start, including unrevealed secret, super secret and ultra secret rooms, with type, shape, layout id and seeds. **[C]**
2. You can read an unvisited room's layout (`Data.Spawns`). Tinted rocks are known in advance only when the layout places them; the random rock conversions made at first entry are not exposed for other rooms. **[C]/[U]**
3. Item prediction is feasible:
   - Each layout entity's `InitSeed` is a pure function of `RoomDescriptor.SpawnSeed`: `InitSeed = X35(X11^k(SpawnSeed))`. In our logs it matched 443 of 443 first-visit pickups across 203 rooms, and it agrees with an independent reconstruction (ESF). **[C-log]**
   - `k` is the spawn's fixed position in its layout. One in-game calibration is still needed to tie `k` to the `Data.Spawns` index. **[U]**
   - Feeding the seed to `ItemPool:GetCollectible(pool, false, seed)` should yield the pedestal item. That the game uses `InitSeed` as the pick seed is likely but untested. **[U]**
4. `GetCollectible(…, false, seed)` is **not provably free of side effects**:
   - It overwrites the item pool's "last pool" (`GetLastPool`). **[C]**
   - It fires `MC_PRE/POST_GET_COLLECTIBLE` in every loaded mod. **[C]**
   - With TMTRAINER it probably creates a glitched item. **[U]**
   - With the seed omitted, the vanilla wrapper calls `Random()`. **[C]**
   - It probably leaves pool weights, removals and the room blacklist alone. **[U]**

   Mitigations are in §3.5: always pass a seed, skip TMTRAINER, restore the last pool, and guard re-entrancy.
5. Boss-reward pedestal seed = `X35^k(AwardSeed)`, with `k` = 3 (2 for Mom and Conquest in our logs). This assumes `AwardSeed = X12(SpawnSeed)`. **[C-log]/[U]**

Notation: `Xn(s)` is one `RNG:Next()` with shift index `n`, and `Xn^k` is k consecutive calls.

---

## 0. Isaac RNG (needed for everything below)

- **[C]** `RNG::Next()` is a 32-bit xorshift: `x ^= x >> a; x ^= x << b; x ^= x >> c` with `(a,b,c) = table[ShiftIdx]`. The table holds Marsaglia's 81 triplets. Seed 0 asserts or crashes. Sources:
  - RGON `libzhl/functions/RNG.zhl`: the byte signature of `RNG::Next` decodes to `shr cl1 / xor / shl cl2 / xor / shr cl3 / xor`, preceded by a zero-seed assert.
  - EID `features/eid_itemprediction.lua`: `xortable` and `EID:RNGNext`.
  - IsaacDocs `RNG`: new RNG objects start at seed 2853650767, valid shift indexes are 0–80, 35 is recommended, and seed 0 crashes.
- **[C]** `SetSeed(seed, idx)` only stores the seed and shift and does not advance. This is consistent with IsaacDocs' `getShiftIdx` snippet, Blade's gist and ESF `rng.hpp`.
- **[U]** `RandomFloat() = Next() * 2.3283061589829401e-10` and `RandomInt(n) = Next() % n`. This is how EID (`SeedToFloat`, Bag of Crafting `nextFloat`), ESF (`item.hpp`) and Blade's Eden gist reproduce game results. These are reconstructions, not the binary.
- Shift indexes used by the game paths in this note: 35 = (5,9,7) is the default; 11 = (2,7,7) is the room spawn RNG; 12 = (2,7,9) is room seed initialisation; 4 = (1,11,6) is the `GetCollectible` pick (ESF `get_collectible`). **[C-log]** for 11, 12 and 35; **[U]** for 4.
- **Read-only rules.**
  - Never call `Next/RandomInt/RandomFloat` on game-owned RNG objects (`GetDropRNG`, `GetCollectibleRNG`, `GetCardRNG`, `GetDevilAngelRoomRNG`, `GridEntity:GetRNG`, …). Read them only with `:GetSeed()`, as EID does with `player:GetTrinketRNG(32):GetSeed()`. **[C]**
  - Avoid API defaults that call `Random()`. The vanilla `main.lua` wrappers substitute `Random()` for an omitted seed in `ItemPool:GetCollectible` and `Sprite:PlayRandom`. **[C]** Whether the global `Random()` stream is part of the lockstep state is unknown. **[U]**

```lua
-- Pure-Lua xorshift (Lua 5.3 integers). Same results as RNG():SetSeed(s, idx); RNG:Next()
local M32 = 0xFFFFFFFF
local SHIFT = { [4] = {1,11,6}, [11] = {2,7,7}, [12] = {2,7,9}, [35] = {5,9,7} } -- full table: EID xortable
local function X(seed, idx)
  local s = SHIFT[idx]
  seed = seed ~ (seed >> s[1])
  seed = seed ~ ((seed << s[2]) & M32)
  seed = seed ~ (seed >> s[3])
  return seed & M32
end
local function u32(n) return n & M32 end   -- descriptor seeds may surface as signed ints
```

We checked this snippet offline with Lua 5.3 against the log values in §3.2. For example, treasure room 4.12 with SpawnSeed 1721222884 and k=5 gives 2444890266 (0x91ba109a), the logged pedestal seed of My Reflection. A sign-wrapped input gives the same result.

## 1. Floor map

| Item | Status | Notes / source |
|---|---|---|
| `Level:GetRooms()` → RoomList with `.Size`, `:Get(i)` (0-based) and `#list` | [C] | IsaacDocs `Level.GetRooms`, `CppContainer_ArrayProxy_RoomDescriptor`. Returns **read-only** descriptors in creation order; `i == desc.ListIndex`. |
| Contents | [C] | Every room of every dimension (main, mirror/mines-escape, Death Certificate), plus off-grid rooms (negative index) once they exist. ISC `getReadOnlyRooms`: iterating `GetRooms` is "the best way to see if off-grid rooms have been initialized". |
| Secret and super secret rooms | [C] | In the list from floor start. MMAPI `LoadDefaultMap` builds its map from `GetRooms` on `MC_POST_NEW_LEVEL`. |
| Ultra secret room (`RoomType.ROOM_ULTRASECRET` = 29) | [C] | In the list from floor generation, with `DisplayFlags == 0` until revealed. MMAPI special-cases it in `maproomfunctions:GetDisplayFlags`. Wiki: Cracked Orb and Rune Shard reveal it, and The Moon teleports into it. It may not be generated at all when no valid spot exists. |
| Red rooms | [C] | Absent until created (Red Key, Cracked Key, Soul of Cain, …). They are then **appended** (new ListIndex) with `Flags & RoomDescriptor.FLAG_RED_ROOM` (1<<10). MMAPI `CheckForNewRedRooms` polls `#rooms` and scans from its last count. |
| `Level:GetRoomByIdx(idx, dim = -1)` | [C] | Always returns a descriptor; for an empty slot, `Data == nil`. It returns the **writable** descriptor (IsaacDocs `ShopItemIdx` example), so never assign to it: writing `DisplayFlags` and similar fields changes game state. dim: -1 current, 0 main, 1 mirror/mines escape, 2 Death Certificate. |
| Room dimension | [C] | `GetPtrHash(level:GetRoomByIdx(d.SafeGridIndex, dim)) == GetPtrHash(d)` for dim 0..2 (IsaacDocs `RoomDescriptor.GridIndex` snippet). MMAPI adds a fallback for a known mismatch (seed GHXY AG8J, Mines 2). |
| Off-grid indexes (`GridRooms`) | [C] | -1 devil/angel, -2 I AM ERROR, -3 debug/goto, -4 crawlspace, -5 Boss Rush, -6 black market, -7 Mega Satan, -8 Blue Womb, -9 Void, -10 secret exit, -11 Gideon dungeon, -12 Genesis, -13 secret shop, -14/-15 Rotgut, -16 blue room, -17 extra boss, -18 angel shop (stairway), -19 deathmatch (Rep+), -20 Lil Portal (Rep+). -100 (mirror) and -101 (mineshaft) are door targets, not rooms. `MAX_GRID_ROOMS` = 507. ISC: `SafeGridIndex` is wrong for some off-grid rooms (e.g. Genesis), so use `Level:GetCurrentRoomIndex()` there. |
| Devil/angel room at -1 | [U] | `Data` is nil until the deal is initialised (deal door spawned). Re-poll after boss kills. |
| Descriptor fields | [C] | `GridIndex`, `SafeGridIndex`, `ListIndex`, `VisitedCount`, `Clear`, `ClearCount`, `DisplayFlags`, `Flags`, `SpawnSeed`, `AwardSeed`, `DecorationSeed`, `Data`, `OverrideData`. `AllowedDoors` is unusable userdata (IsaacDocs bug note) and `Data.Mode` is broken userdata. |
| `Data` (RoomConfigRoom) | [C] | `Type`, `Variant`, `Subtype`, `Shape`, `Name`, `Difficulty`, `StageID`, `Doors` (DoorSlot bitmask), `Width`, `Height`, `Weight`, `Spawns`, `SpawnCount`. `Data.Type.Variant(Name)` is what the game log prints as `Room 4.12()` **[C-log]**. |
| `DisplayFlags` | [C] | Bit0 visible, bit1 shadow/locked look, bit2 icon. Typical values: 0b000 hidden, 0b101 normal, 0b011 secret/locked pre-entry. Special room types differ (IsaacDocs). |
| Seeds | [C] | IsaacDocs: `SpawnSeed` is "used to spawn entities at room load"; `AwardSeed` spawns clear awards and initialises shop items; `DecorationSeed` is cosmetic. All three are set at floor generation (RGON `RoomDescriptor::InitSeeds(RNG*)`). Read them as `u32(x)`. |

**Room shapes and cells.** **[C]** The level grid is 13×13 with `index = row*13 + col` (IsaacDocs `GridIndex`, MMAPI `GridIndexToVector`). Anchor every room on `SafeGridIndex`, which is its top-left cell except for `ROOMSHAPE_LTL`. For LTL, `SafeGridIndex` is the top-right cell and `GridIndex` is the *missing* top-left cell. Offsets come from MMAPI `data.lua` `RoomShapePositions`:

```lua
local SHAPE_CELLS = {
  [RoomShape.ROOMSHAPE_1x1] = {{0,0}}, [RoomShape.ROOMSHAPE_IH] = {{0,0}}, [RoomShape.ROOMSHAPE_IV] = {{0,0}},
  [RoomShape.ROOMSHAPE_1x2] = {{0,0},{0,1}}, [RoomShape.ROOMSHAPE_IIV] = {{0,0},{0,1}},
  [RoomShape.ROOMSHAPE_2x1] = {{0,0},{1,0}}, [RoomShape.ROOMSHAPE_IIH] = {{0,0},{1,0}},
  [RoomShape.ROOMSHAPE_2x2] = {{0,0},{1,0},{0,1},{1,1}},
  [RoomShape.ROOMSHAPE_LTL] = {{0,0},{-1,1},{0,1}},   -- anchor = top-right
  [RoomShape.ROOMSHAPE_LTR] = {{0,0},{0,1},{1,1}},
  [RoomShape.ROOMSHAPE_LBL] = {{0,0},{1,0},{1,1}},
  [RoomShape.ROOMSHAPE_LBR] = {{0,0},{1,0},{0,1}},
}

local function readFloor()            -- pure reads; call on MC_POST_NEW_LEVEL / MC_POST_NEW_ROOM / when #rooms grows
  local level = Game():GetLevel()
  local list, out = level:GetRooms(), {}
  for i = 0, list.Size - 1 do
    local d = list:Get(i)
    if d and d.Data then
      local dim = -1
      for k = 0, 2 do
        if GetPtrHash(level:GetRoomByIdx(d.SafeGridIndex, k)) == GetPtrHash(d) then dim = k break end
      end
      local cells = {}
      if d.SafeGridIndex >= 0 then
        local x0, y0 = d.SafeGridIndex % 13, d.SafeGridIndex // 13
        for _, o in ipairs(SHAPE_CELLS[d.Data.Shape] or {{0,0}}) do
          cells[#cells + 1] = (y0 + o[2]) * 13 + (x0 + o[1])
        end
      end
      out[#out + 1] = {
        list = d.ListIndex, grid = d.GridIndex, safe = d.SafeGridIndex, dim = dim, cells = cells,
        type = d.Data.Type, variant = d.Data.Variant, subtype = d.Data.Subtype, shape = d.Data.Shape,
        name = d.Data.Name, visited = d.VisitedCount > 0, clear = d.Clear, display = d.DisplayFlags,
        red = (d.Flags & RoomDescriptor.FLAG_RED_ROOM) ~= 0,
        devilTreasure = (d.Flags & RoomDescriptor.FLAG_DEVIL_TREASURE) ~= 0,
        spawnSeed = u32(d.SpawnSeed), awardSeed = u32(d.AwardSeed),
      }
    end
  end
  return out
end
```

**Gotchas.** **[C]**
- `GetPoolForRoom(ROOM_DEFAULT)` returns -1 (see §3).
- MMAPI shows `Data.Type == ROOM_CHALLENGE` with `Subtype == 1` as a boss challenge, and `FLAG_DEVIL_TREASURE` treasure rooms with the red treasure icon.
- On alt-path floors, mirror rooms are `ROOM_DEFAULT` with subtype 34 and minecart rooms subtype 10 (MMAPI `LoadDefaultMap`).
- Greed mode has the extra treasure room at grid index 85.

## 2. Room layout contents before entering

**Reading spawns.**
- **[C]** `desc.Data.Spawns` is readable for **unvisited** rooms. StageAPI `StageAPI.EntityInLevel` iterates `Level:GetRooms():Get(i).Data` spawns for every room; IsaacDocs documents `RoomConfigSpawns` (`.Size`, `:Get(i)`, 0-based) and `RoomConfigSpawn` (`X`, `Y`, `EntryCount`, `SumWeights`, `PickEntry(r)`, `Entries`); each `RoomConfigEntry` has `Type`, `Variant`, `Subtype` and `Weight`.
- **[C]** Known-working way to list a spawn's candidates: StageAPI `ForAllSpawnEntries` calls `PickEntry(acc)` while accumulating `acc += entry.Weight / SumWeights`.
- **[U]** `Entries:Get(j)` is documented but StageAPI avoids it; treat it as unverified.
- **[C]** Layout `X,Y` are interior coordinates. The room grid index is `(Y+1)*W + (X+1)`, where W is 15 for 1x1/IH/IV/1x2/IIV and 28 for 2x1/IIH/2x2/L shapes (StageAPI `VectorToGrid`, `RoomShapeToWidthHeight`). **[U]** whether `Data.Width` equals this W.
- **[U]** Weighted multi-entry spawns (random enemies or pickups) are resolved at first entry, so before entry you only know the candidate list. `OverrideData` replaces `Data` for surprise minibosses (`FLAG_SURPRISE_MINIBOSS`).

```lua
local GRID_W = { [1]=15,[2]=15,[3]=15,[4]=15,[5]=15, [6]=28,[7]=28,[8]=28,[9]=28,[10]=28,[11]=28,[12]=28 }
local function layoutSpawns(desc)
  local data, out = desc.Data, {}
  local spawns, w = data.Spawns, GRID_W[data.Shape] or 15
  for i = 0, spawns.Size - 1 do
    local s = spawns:Get(i)
    if s then
      local entries, acc = {}, 0
      for _ = 1, s.EntryCount do
        local e = s:PickEntry(acc)
        entries[#entries + 1] = { type = e.Type, variant = e.Variant, subtype = e.Subtype, weight = e.Weight }
        acc = acc + e.Weight / s.SumWeights
      end
      out[#out + 1] = { index = i, gridIndex = (s.Y + 1) * w + (s.X + 1), entries = entries }
    end
  end
  return out
end
```

**Spawn type codes.** **[C]** These come from RGON `eRoomSpawnType` (Global.zhl) and the `StbGridType` docs; the GridEntityType mapping comes from StageAPI `CorrectedGridTypes`.
- Decoration: 0 decoration; 999 effect (in `MC_PRE_ROOM_ENTITY_SPAWN`, effects report type 999).
- Rocks: 1000 rock (`GRID_ROCK`), 1001 bomb rock, 1002 alt rock (`GRID_ROCK_ALT`), **1003 tinted rock (`GRID_ROCKT`)**, 1008 marked skull (`GRID_ROCK_ALT2`), 1009 event rock, 1010 spiked rock, 1011 fool's gold rock (`GRID_ROCK_GOLD`).
- Hazards and poops: 1300 TNT; 1490/1494–1501 poops (red, rainbow, corn, golden, black, holy, giant, normal, charming).
- Blocks: 1900 block, 1901 pillar, 1930/1931 spikes, 1940 cobweb, 1999 invisible block.
- Pits and rails: 3000 pit, 3002 event rail, 3009 event pit.
- Interactables: 4000 key block, 4500 pressure plate, 5000/5001 devil/angel statue, 6000/6001 rail, 6100 teleporter.
- Exits: 9000 trapdoor, 9100 crawlspace, 10000 gravity.
- Entities use EntityType. `5.100.0` is a random collectible, `5.0.0` a random pickup and `5.350.0` a random trinket.

**Rock types: layout vs random.**
- **[C]** Layout-placed special rocks (1001/1002/1003/1008/1010/1011) are readable in advance.
- **[U]** Random conversion of plain `1000` rocks at room init, per StageAPI's emulation of vanilla (`roomHandler.lua`, `PRE_SPAWN_GRID` handler; it uses its own RNG, so only the rules carry over):
  - The rock at `Room:GetTintedRockIdx()` becomes tinted, or super special with 5% chance if achievement 323 is unlocked.
  - Any other rock: 1% fool's gold (one cluster per room, achievement 612), 2% bomb rock (not near doors), 4% alt rock.
  - Wiki: one tinted rock per room; super special excludes normal tinted; fool's gold "small chance of replacing normal rocks, sometimes in small clusters"; bomb rocks "small chance of replacing any rock"; Repentance hard mode changed the tinted rate.
- **Conclusion:** tinted rocks of an unvisited room can be known only if the layout places them. **[C]** `GetTintedRockIdx` exists only for the current room. The algorithm that picks it is unknown, but it may be a function of the room seeds; see §7 for the test. **[U]**

**Reward rocks in the current (visited) room.** Scan `Room:GetGridEntity(i)` for `i = 0 .. room:GetGridSize()-1`; `GetType()` gives the kind, and `State == 2` marks a destroyed rock (IsaacDocs `GridEntity.State`). Drops are from the wiki `Rocks` page (**[C]** wiki):

| GridEntityType | What | Drops |
|---|---|---|
| 4 `GRID_ROCKT` | tinted rock | 1–2 of: soul heart(s), bomb, key, locked chest 17.1%, chest 0.9%; The Small Rock 10% if unlocked |
| 22 `GRID_ROCK_SS` | super special rock | double tinted-rock rewards (single chest/Small Rock stays single) |
| 6 `GRID_ROCK_ALT` | urn / mushroom / skull / polyp / bucket (by stage) | 68% nothing. Urn: coins, Swallowed Penny, Quarter, spiders. Mushroom: pill, Liberty Cap, Magic Mushroom/Mini Mush, gas. Skull: card/rune, Black Heart, Dry/Ghost Baby, Host. Polyp: heart, Umbilical Cord, Blood Clot/Placenta, creep ring. Bucket: coins, Swallowed Penny/Butt Penny, Leech/The Poop, enemies |
| 26 `GRID_ROCK_ALT2` | marked ("x") skull | 0 - The Fool (Depths/Necropolis/Dank Depths II or XL, after defeating Mother) |
| 27 `GRID_ROCK_GOLD` | fool's gold | 2–4 pennies |
| 5 `GRID_ROCK_BOMB` | bomb rock | explodes |
| 25 `GRID_ROCK_SPIKED` | spiked rock | hurts on contact |

Vanilla Lua cannot read the saved grid state of other rooms (`SavedGridEntities` is a REPENTOGON-only field), so cache it while you are in the room. **[C]** (RGON `RoomDescriptor.zhl`)

## 3. Item prediction

> **Superseded in part by [item-emulation.md](item-emulation.md)** (decompiled from the game): the pick seed is `X35(InitSeed)`, not `InitSeed`; `k` = `Data.Spawns` index + 1; and the item can be predicted with a pure-Lua copy of the pools, without calling `ItemPool:GetCollectible`. The mod does that since 0.22.0.

### 3.1 What the log lines are

- `Room T.V(Name)` is printed on every room load and equals `Data.Type.Variant` (`Name`). **[C-log]**
- `[Frame f] SpawnRNG seed: N` is printed on every room load. It is identical on every revisit of the same room, so it is the room's `RoomDescriptor.SpawnSeed` (= `Room:GetSpawnSeed()`) in unsigned decimal. **[C-log]** ESF names the same quantity "Room::GetSpawnSeed()".
- `Entity Pickup Initialized as: 5.V.S  Seed: hex` is printed after the pickup variant/subtype is resolved. `Seed` is the entity's `InitSeed`. It is re-printed with the same seed on revisits, because saved entities keep their seed. **[C-log]** ESF computes this value as "Entity::InitSeed" and matches it in game against Lua `e.InitSeed` (`main_baby_plum.lua`).

### 3.2 Seed of a layout-spawned entity (pedestal) — the key result

```
InitSeed(k) = X35( X11^k( SpawnSeed ) )      k = 1, 2, 3 …  (position in the room's spawn sequence)
```

- **[C-log]** Method: 58 run logs (`/wuxie/data/isaac-dodge/logs/runs/*.log.gz`, 2026-11-04/05). We brute-forced all 81 shift indexes × chain lengths and found the two-stage form (shift 11 chain, then one shift 35 step) on five treasure rooms.
- **[C-log]** We then tested every pickup initialised in the room-load frame of a first visit: 102/102 collectibles, 340/340 other pickups (coins, hearts, keys, bombs, chests, cards…) and 1/1 trinket matched, across 203 rooms. Room types covered: treasure, shop, devil, angel, curse, secret, library, chest room, crawlspace and normal rooms.
- **[C-log]** `k` depends only on the layout, not on the run:
  - Treasure 4.26 gives k=1 in four runs; 4.27 gives 21 in two runs; 4.12 gives 5 twice.
  - Devil 14.20 gives items at 10/11/12 in two runs.
  - Shop 2.1 gives slots 5/6/7 in eleven visits.
  - Neighbouring spawns use consecutive k: devil 14.4 has items at 4 and 6 with a red chest at 5.
  - The crawlspace (16.7) item is at k=63, so grid spawns count too.
- **[C]** Independent confirmation: ESF `eden.hpp` `to_entity_seed()` = `Rng{room_spawn_seed, 11}.advance(6)` then `Rng{s, 35}.next()`. `advance(n)` runs n+1 steps, so this is k=7 for a Home-room pickup. `generator_baby_plum.cpp` uses k ∈ {1,3,7,12} for the Baby Plum layouts.
- **[U]** **Open link:** is `k = (index in Data.Spawns) + 1` with exactly one step per spawn (grid spawns included, no extra step for weighted entries)? This fits every observation but is not proven; calibrate with the logger in §3.6. Until then a per-layout table `(Type, Variant, spawnIndex) → k`, learned on first visits and persisted with `Isaac.SaveModData`, is a safe fallback, because layouts recur across runs.
- **[C-log]** Boss reward (first pedestal after the kill): `seed = X35^k( X12(SpawnSeed) )`, with k=3 in 24 of 28 boss rooms and k=2 in 4 (Mom ×3, Conquest). All 28 first pedestals matched; most later pedestals (6 of 34 matched) come from other sources. **[U]** We expect `X12(SpawnSeed) == desc.AwardSeed` (IsaacDocs: AwardSeed spawns clear awards; ESF `to_room_seed` derives room seeds as consecutive shift-12 steps). Assert this in game, then use `desc.AwardSeed` directly. The k=2 versus k=3 branch, and Rep+ boss-thematic items (RGON `Room::GetBossThematicItem`), make boss prediction lower confidence.

### 3.3 Which item that seed produces

- **[C]** Engine path (RGON `ItemPool.zhl`, `Room.zhl` signatures):
  1. `ItemPool::GetSeededCollectible(seed, noDecrease, RoomDescriptor*)`
  2. `Room::GetItemPool(seed, roomDesc, boss)`
  3. `ItemPool::GetCollectible(pool, seed, flags, defaultItem)`
- **[C]** Vanilla Lua exposes `ItemPool:GetPoolForRoom(roomType, seed)` and `ItemPool:GetCollectible(pool, decrease, seed, default, backupPool)`. It also has `Room:GetSeededCollectible(seed, noDecrease)`, but that one uses the **current** room's descriptor.
- **[C]** `GetPoolForRoom` gaps (Repentance API issue tracker):
  - #155: returns -1 for `ROOM_DEFAULT`; the game uses the treasure pool there.
  - #323: ignores Devil's Crown (treasure → devil; check `FLAG_DEVIL_TREASURE`) and Adoption Papers (shop → baby shop).
  - #422: the Greed silver treasure room reports the gold pool.
  - EID calls it with a constant seed (`eid_modifiers.lua`, `GetPoolForRoom(roomType, 69)`), so treat it as a pure query.
- **[U]** The game passes the pedestal's `InitSeed` to `GetCollectible` unchanged. This is likely, but verify it with the `MC_PRE_GET_COLLECTIBLE` seed argument (§3.6).
- **[U]** Pick algorithm (ESF `item.hpp`, a reconstruction for Rep 1.7.9b that the author says also works on Rep+):
  - `r = RNG(seed, shift 4)`; `target = r:Next() * 2^-32 * pool.totalWeight`.
  - Walk the run-shuffled pool list (MT19937 shuffle from the start seed).
  - Skip items that are removed or blacklisted in the room, and repick from the remainder fraction (up to about 10 tries).
  - When `decrease` is set: weight -= DecreaseBy, remove the item below RemoveOn, and room-blacklist it.
  - Achievement checks, NO!, TMTRAINER, Chaos, Sacred Orb/T.Lost quality filters, Magic Skin/Rosary/Bible morphs and pool exhaustion (Breakfast) sit around that core (IsaacDocs `GetCollectible` notes; RGON `PickCollectible` "differences" list).
- **Validity window.** **[C]** (follows from the above) The result depends on the live pool state, player items and room blacklist, so recompute after every item spawn.
  - If the predicted item spawns elsewhere first, the real pedestal re-picks and gets something else.
  - In a room with two random pedestals the game removes the first before rolling the second. A Decrease=false prediction of the second can then collide with the first; flag equal predictions as uncertain.
  - Glitched Crown, Tainted Isaac and similar cycling items, as well as rerolls, change pedestals after spawn.

### 3.4 Prior art

- **[C]** EID predicts outcomes by emulating RNG in Lua: D Infinity, Metronome, Teleport!/Teleport 2.0, D1, Glyph of Balance, Crooked Penny, Experimental Treatment, Dataminer, Liberty Cap/Broken Syringe/Mom's Lock, Sanguine Bond and Void (`eid_itemprediction.lua`).
- **[C]** EID's Bag of Crafting uses its own pool copies (from XML) plus its own xorshift (`eid_bagofcrafting.lua`). In vanilla mode EID never calls `ItemPool:GetCollectible`; with REPENTOGON it uses `GetCollectiblesFromPool`.
- **[C]** ESF emulates Eden items and Home-room spawns offline in C++, including the item-pool MT19937 shuffle and `pick_collectible`, then confirms candidate seeds in game.
- **[U]** isaac.libido.cc ("Repentance+ 1.9.7.17 data") and the exchive.com Seed Analyser claim to show floors, bosses and **pedestal items** for a seed. Both are closed and server-side.
- **[U]** We found no open-source vanilla mod that previews items in *unvisited* treasure rooms. Nayoh's "First Item" forces an item rather than predicting it.
- **[U]** A pure-Lua, zero-call emulation is possible in principle (itempools.xml + MT19937 shuffle + full removal history + unlock state), but it is fragile and not recommended.

### 3.5 Side effects of `ItemPool:GetCollectible(pool, false, seed)`

| Effect | Status | Evidence / mitigation |
|---|---|---|
| Removes the item or lowers its weight | **[U] no** | Vanilla `main.lua` wrapper: `ItemPool_GetCollectible(self, poolType, seed or Random(), (decrease and 0) or 1, defaultItem or 0, backupPool or -1)`, so false sends the native "no decrease" flag. ESF's reconstruction only decrements weight and room-blacklists when decreasing. We found no bug report of Decrease=false removing items (tracker search; the only Rep+ GetCollectible issue, #610, was a crash fixed in 1.9.7.14). |
| Consumes a game RNG | **[U] no**, if a seed is passed | It uses a local RNG built from the seed (ESF). **[C]** Omitting the seed makes the wrapper call `Random()`, so always pass a non-zero seed. |
| Sets the item pool's last pool (`GetLastPool()`) | **[C] yes** | IsaacDocs `MC_PRE/POST_GET_COLLECTIBLE` notes: `GetLastPool()` tells which pool "is actually going to be used", Chaos included. It is saved run state (RGON `GameStateItemPool._lastPool`). Before 1.9.7.11 it drove the D4 "last pool" exploit (EID `eid_api.lua` `getObjectItemPool` comment); current readers are unknown. **Mitigation:** save `GetLastPool()` before the call and restore it afterwards by calling `GetCollectible(saved, false, 1)` while `saved >= 0`; check with `GetLastPool()` (under Chaos the restore can miss, so skip or log it). |
| Fires `MC_PRE_GET_COLLECTIBLE` / `MC_POST_GET_COLLECTIBLE` (62/63) in all mods | **[C] yes** | Implied by RGON `PickCollectible` docs ("Does not trigger … unlike GetCollectible"). Another mod might act on them. Guard your own handlers with a re-entrancy flag. |
| TMTRAINER: creates a glitched item | **[U] likely** | RGON `PickCollectible`: "Does not generate a Glitched Item when having TMTRAINER", in contrast to GetCollectible. `ProceduralItemManager.CreateProceduralItem` adds an item, which is a state change. **Do not predict while any player has COLLECTIBLE_TMTRAINER (721).** |
| Chaos / Magic Skin / Rosary / Bible morphs | **[U] deterministic** | Driven by the passed seed (`ItemPool::TryReplaceWithMagicSkin(seed)` is static). Bible morph counters (`_bibleUpgrade`) are untested. |

Net: prediction is feasible with **near-zero** side effects. The only state write that is confirmed (the last pool) can be restored. Fully proven purity would need either a REPENTOGON-free emulation or a binary check of `ItemPool::GetCollectible`. The repo's own RE workflow (`native/research/findings.md`) could do that check on `isaac-ng.exe` using the RGON signature `558bec81ecac000000a1`.

### 3.6 Code: predictor and passive calibration logger

```lua
local game, itemPool = Game(), Game():GetItemPool()
local predicting = false

local function anyoneHas(id)
  for i = 0, game:GetNumPlayers() - 1 do
    if Isaac.GetPlayer(i):HasCollectible(id) then return true end
  end
  return false
end

local function layoutSeed(spawnSeed, k)      -- §3.2
  local v = u32(spawnSeed)
  for _ = 1, k do v = X(v, 11) end
  return X(v, 35)
end

local function poolFor(desc, seed)          -- §3.3 fix-ups
  local pool = itemPool:GetPoolForRoom(desc.Data.Type, seed)
  if desc.Data.Type == RoomType.ROOM_TREASURE and (desc.Flags & RoomDescriptor.FLAG_DEVIL_TREASURE) ~= 0 then
    pool = ItemPoolType.POOL_DEVIL
  end
  if pool < 0 then pool = ItemPoolType.POOL_TREASURE end
  return pool
end

local function predictCollectible(desc, k)
  if anyoneHas(CollectibleType.COLLECTIBLE_TMTRAINER) then return nil end
  local seed = layoutSeed(desc.SpawnSeed, k)
  local pool = poolFor(desc, seed)
  local saved = itemPool:GetLastPool()
  predicting = true
  local id = itemPool:GetCollectible(pool, false, seed)          -- explicit seed: no Random()
  if saved >= 0 and itemPool:GetLastPool() ~= saved then
    itemPool:GetCollectible(saved, false, 1)                      -- restore last pool
  end
  predicting = false
  return id, seed, pool
end
-- usage: for each unvisited room, for each spawn s in layoutSpawns(desc) whose only entry is 5.100.0,
--        predictCollectible(desc, s.index + 1)    -- k rule pending calibration (§3.2)
```

The calibration logger is read-only. Every handler returns nil, so the game is unchanged. It writes to `log.txt`, which the existing log pipeline already collects.

```lua
local function L(fmt, ...) Isaac.DebugString(string.format("IAD MAPCAL " .. fmt, ...)) end

mod:AddCallback(ModCallbacks.MC_PRE_ROOM_ENTITY_SPAWN, function(_, t, v, st, gridIdx, seed)
  local d = game:GetLevel():GetCurrentRoomDesc()
  L("SPAWN room=%d.%d ss=%d as=%d t=%d v=%d s=%d g=%d seed=%d",
    d.Data.Type, d.Data.Variant, u32(d.SpawnSeed), u32(d.AwardSeed), t, v, st, gridIdx, u32(seed))
end)

mod:AddCallback(ModCallbacks.MC_PRE_GET_COLLECTIBLE, function(_, pool, decrease, seed)
  if not predicting then L("GETCOL pool=%d dec=%s seed=%d", pool, tostring(decrease), u32(seed)) end
end)

mod:AddCallback(ModCallbacks.MC_POST_PICKUP_INIT, function(_, p)
  L("PICKUP %d.%d seed=%d", p.Variant, p.SubType, u32(p.InitSeed))
end)

mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
  local d, room = game:GetLevel():GetCurrentRoomDesc(), game:GetRoom()
  if room:IsFirstVisit() then
    L("ROOM %d.%d ss=%d as=%d tinted=%d spawns=%d", d.Data.Type, d.Data.Variant,
      u32(d.SpawnSeed), u32(d.AwardSeed), room:GetTintedRockIdx(), d.Data.Spawns.Size)
  end
end)
```

Offline you can then check the remaining links:
- k against the `Data.Spawns` index;
- the `MC_PRE_ROOM_ENTITY_SPAWN` seed against `X11^k` / `InitSeed`;
- the `GETCOL` seed against the pedestal's `InitSeed`;
- `AwardSeed` against `X12(SpawnSeed)`;
- `GetTintedRockIdx` against the room seeds.

## 4. Reading items in a visited room

- **[C]** Use `Isaac.FindByType(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE)` and `pickup.SubType`, which is the real item ID **even under Curse of the Blind and for alt-path "?" pedestals**. EID shows the real description from SubType and hides it only by config. Its alt-path check is purely visual: `EID:IsAltChoice` compares sprite texels with `questionmark.png`. SubType 0 means an empty pedestal.
- **[C]** Vanilla has no blind flag; `EntityPickup:IsBlind()` is REPENTOGON-only. Use `Level:GetCurses() & LevelCurse.CURSE_OF_BLIND` and the EID texel trick for alt-path items.
- **[C]** `Isaac.GetItemConfig():GetCollectible(id)` (nil if invalid) has `Name`, `Description`, `Quality` (0–4), `Tags` (+ `HasTags`), `Type`, `ShopPrice`, `DevilPrice`, `GfxFileName` (pedestal sprite path, usable for icons), `AchievementID`, `Hidden` and `IsAvailable()`.
- **[C]** In Repentance, `Name` and `Description` return localisation keys such as `#THE_SAD_ONION_NAME` (IsaacDocs warning). Vanilla has no string-table API (`Isaac.GetString` and `GetLocalizedString` are REPENTOGON). Ship a name table instead: EID `descriptions/names/en_us.lua` / `zh_cn.lua`, keyed `"5.100.<id>"`; check EID's license before copying. **[U]** Modded items return their literal name.
- **[C]** `EntityPickup` fields:
  - `Price`: 0 = not for sale, >0 = coins. Negative values are `PickupPrice`: -1 one heart, -2 two hearts, -3 three soul hearts, -4 heart+2 soul, -5 spikes, -6 soul, -7 one soul heart, -8 two soul hearts, -9 heart+soul, -10 devil-sacrifice spikes; -1000 free.
  - `ShopItemId`: the shop slot; -1/-2 mark non-shop/devil pricing.
  - `OptionsPickupIndex`: ≠0 forms a "choose one" group.
  - `Touched`, `Wait`, `IsShopItem()`.
- **[U]** TMTRAINER glitched items surface as very large or negative SubType values. Cycling pedestals (Glitched Crown, Tainted Isaac) change SubType over time, so re-read every frame.

## 5. Rendering an overlay map (vanilla)

- **[C]** Render in `MC_POST_RENDER`; vanilla has no HUD render callback (that is REPENTOGON). Use these helpers:
  - `Isaac.GetScreenWidth()` / `GetScreenHeight()` (Rep/Rep+)
  - `Isaac.GetScreenPointScale()`, `Options.HUDOffset` (0–1)
  - `Game():GetHUD():IsVisible()`, `Game():IsPaused()`
  - `Isaac.WorldToScreen(pos)`
- **[C]** Vanilla sprites: `gfx/ui/minimap1.anm2` (small) and `gfx/ui/minimap2.anm2` (large) have the animations `RoomVisited`, `RoomUnvisited`, `RoomCurrent`, `RoomOutline` and `Frame`. In `RoomVisited`/`RoomCurrent` the frame is chosen by shape, `frame = RoomShape - 1` (MMAPI `RoomShapeFrames`: 1x1→0, IH→1, IV→2, 1x2→3, IIV→4, 2x1→5, IIH→6, 2x2→7, LTL→8, LTR→9, LBL→10, LBR→11).
- **[C]** Icons are in `gfx/ui/minimap_icons.anm2` with `"Icon" .. id` at frame 0: `IconTreasureRoom`, `IconTreasureRoomRed`, `IconTreasureRoomGreed`, `IconSecretRoom`, `IconSuperSecretRoom`, `IconUltraSecretRoom`, `IconShop`, `IconBoss`, `IconMiniboss`, `IconAngelRoom`, `IconDevilRoom`, `IconCurseRoom`, `IconSacrificeRoom`, `IconLibrary`, `IconArcade`, `IconChestRoom`, `IconDiceRoom`, `IconIsaacsRoom`, `IconBarrenRoom`, `IconPlanetarium`, `IconLockedRoom`, `IconAmbushRoom`, `IconBossAmbushRoom`, `IconMirrorRoom`, `IconMinecartRoom`, `IconTeleporterRoom`, `IconItem`, `IconTrinket`, `IconChest`, … (MMAPI `resources/gfx/ui/minimap_icons.anm2` and the `data.lua` icon table). The room type → icon map is MMAPI `RoomTypeIconIDs`.
- **[C] Gotcha:** MMAPI **overrides** the vanilla `minimap1.anm2` (its `RoomUnvisited` has 1 frame; `MinimapAPI:IsBadLoad()` relies on this), along with `minimap2.anm2` and `minimap_icons.anm2`. Follow MMAPI's own pattern: ship copies under unique names (e.g. `gfx/ui/iad_minimap1.anm2`) whose `<Spritesheet Path="minimap1.png">` resolves to the vanilla PNG next to it. **[U]** The vanilla anm2 animation names are assumed to equal those in MMAPI's copies.
- Cell pitch: 8×7 px for the small map and 17×15 for the large one (MMAPI `roomSize` / `largeRoomSize`). Draw each room sprite once at its bounding-box top-left cell; for LTL that is `SafeGridIndex` column − 1 (MMAPI `RoomShapeGridPivots`).

```lua
local spr = Sprite()
spr:Load("gfx/ui/iad_minimap1.anm2", true)             -- own copy, see gotcha
local function drawRoom(r, originX, originY)            -- r from readFloor()
  if r.safe < 0 then return end
  local col, row = r.safe % 13, r.safe // 13
  if r.shape == RoomShape.ROOMSHAPE_LTL then col = col - 1 end
  spr:SetFrame(r.visited and "RoomVisited" or "RoomUnvisited", r.shape - 1)
  spr:Render(Vector(originX + col * 8, originY + row * 7))
end
```

- Text:
  - **[C]** `Isaac.RenderText(str, x, y, r, g, b, a)` uses terminus and is ASCII only.
  - **[C]** For CJK, use `Font():Load("font/cjk/lanapixel.fnt")` (the path RGON `resources/scripts/main_ex.lua` uses for "zh") with `font:DrawStringUTF8(str, x, y, KColor(1,1,1,1), boxWidth, center)`; vanilla `main.lua` provides the `DrawStringUTF8` wrapper.
  - **[C]** Fonts shipped with the game: terminus, pftempestasevencondensed, teammeatfont*, luamini(outlined), upheaval(mini), lanapixel, mplus, kr_* (IsaacDocs render-text tutorial).
- Sprite loading and rendering are client-side only. Avoid `Sprite:PlayRandom()` without a seed, because it calls `Random()`.

## 6. Floor-level readouts (pure reads)

| Call | Status | Notes |
|---|---|---|
| `Game():GetRoom():GetDevilRoomChance()` | [C] value; [U] purity | Total deal chance (the "Duality" number). It can exceed 1 and returns values even on floors where no deal can appear. The IsaacDocs example splits it into devil and angel using `Level:GetAngelRoomChance()`, `GameStateFlag.STATE_DEVILROOM_SPAWNED/VISITED`, `STATE_FAMINE_SPAWNED` (repurposed as angel spawned), `Game():GetDevilRoomDeals()` and `GetDonationModAngel()`, plus Key Pieces, Rosary Bead, Eucharist, Book of Virtues and Act of Contrition. The Found HUD shows it every frame, so it is effectively a query. |
| `Level:GetAngelRoomChance()` | [C] | A modifier added to the base 50%; >0 allows angel rooms after a devil deal (IsaacDocs). |
| `Level:GetPlanetariumChance()` | [C] value; [U] purity | 0–1 (Rep/Rep+); also shown by the stat HUD (`Options.StatHUDPlanetarium`). |
| `Game().TimeCounter` | [C] | Game-time frames (30 per second), "used for timed events (bossrush, daily…)". Wiki gates: Boss Rush if Mom is beaten within 20:00 (36000), or 25:00 (45000) on Mausoleum/Gehenna; Blue Womb (Hush) if Mom's Heart/It Lives is beaten within 30:00 (54000). Mama Mega!/Mega Bean, Broken Shovel and Strange Key bypass these. **[U]** frame-exact boundary. |
| `Level:GetCurses()` / `GetCurseName()` | [C] | `LevelCurse` bitmask (`CURSE_OF_DARKNESS`, `_LABYRINTH`, `_THE_LOST`, `_THE_UNKNOWN`, `_THE_CURSED`, `_MAZE`, `_BLIND`, `_GIANT`). |
| `Level:QueryRoomTypeIndex(type, visited, rng)` | [C] | Pass your **own** `RNG()` (ESF, IsaacDocs). It consumes that RNG, not the game's. |

## 7. Open items and the next experiments

1. **k rule** (§3.2/§3.6): compare logged first-visit `PICKUP` seeds with `layoutSeed(ss, i+1)` for every `Data.Spawns` index i. Expect one step per spawn in list order; otherwise learn and persist the offset per layout.
2. **Pick seed:** does `GETCOL seed` equal the pedestal's `InitSeed`? If not, find the transform with the same brute-force search used in §3.2 (the scripts are in `/wuxie/tmp/isaac-api-research-20261105/scripts/`, a temporary location).
3. **Prediction accuracy:** in `MC_PRE_ROOM_ENTITY_SPAWN` for a `5.100.0` spawn, call the predictor and compare it with the later `PICKUP` SubType. The real roll runs right after and overwrites the last pool, so this check does not even need the restore.
4. **AwardSeed:** assert `u32(desc.AwardSeed) == X(u32(desc.SpawnSeed), 12)`. Find what makes boss k = 2 versus 3.
5. **Tinted rocks:** log `GetTintedRockIdx()` with the room seeds and each rock's `GridEntity:GetSaveState().SpawnSeed` on first visits, then search for the relation offline. If it is seed-derived, unvisited tinted rocks become predictable too.
6. **Purity proof (optional):** disassemble `ItemPool::GetCollectible` (RGON signature `558bec81ecac000000a1`) on the installed `isaac-ng.exe` to list every member write when the no-decrease flag is set.

## Sources

- IsaacDocs (Repentance+ API): [Level](https://wofsauge.github.io/IsaacDocs/rep/Level.html), [RoomDescriptor](https://wofsauge.github.io/IsaacDocs/rep/RoomDescriptor.html), [RoomDescriptor list](https://wofsauge.github.io/IsaacDocs/rep/CppContainer_ArrayProxy_RoomDescriptor.html), [RoomDescriptor enum](https://wofsauge.github.io/IsaacDocs/rep/enums/RoomDescriptor.html), [GridRooms](https://wofsauge.github.io/IsaacDocs/rep/enums/GridRooms.html), [RoomShape](https://wofsauge.github.io/IsaacDocs/rep/enums/RoomShape.html), [RoomType](https://wofsauge.github.io/IsaacDocs/rep/enums/RoomType.html), [RoomConfigRoom](https://wofsauge.github.io/IsaacDocs/rep/RoomConfig_Room.html), [RoomConfigSpawns](https://wofsauge.github.io/IsaacDocs/rep/CppContainer_ArrayProxy_RoomConfigSpawns.html), [RoomConfigSpawn](https://wofsauge.github.io/IsaacDocs/rep/RoomConfig_Spawn.html), [RoomConfigEntry](https://wofsauge.github.io/IsaacDocs/rep/RoomConfig_Entry.html), [Room](https://wofsauge.github.io/IsaacDocs/rep/Room.html), [ItemPool](https://wofsauge.github.io/IsaacDocs/rep/ItemPool.html), [RNG](https://wofsauge.github.io/IsaacDocs/rep/RNG.html), [ModCallbacks](https://wofsauge.github.io/IsaacDocs/rep/enums/ModCallbacks.html), [EntityPickup](https://wofsauge.github.io/IsaacDocs/rep/EntityPickup.html), [PickupPrice](https://wofsauge.github.io/IsaacDocs/rep/enums/PickupPrice.html), [ItemConfig Item](https://wofsauge.github.io/IsaacDocs/rep/ItemConfig_Item.html), [GridEntityType](https://wofsauge.github.io/IsaacDocs/rep/enums/GridEntityType.html), [GridEntity](https://wofsauge.github.io/IsaacDocs/rep/GridEntity.html), [Isaac](https://wofsauge.github.io/IsaacDocs/rep/Isaac.html), [Game](https://wofsauge.github.io/IsaacDocs/rep/Game.html), [HUD](https://wofsauge.github.io/IsaacDocs/rep/HUD.html), [Render text tutorial](https://wofsauge.github.io/IsaacDocs/rep/tutorials/Tutorial-Rendertext.html). Repo snapshot [wofsauge/IsaacDocs@88d49ab](https://github.com/wofsauge/IsaacDocs/tree/88d49ab86ce0f694fe1b9c6ed06ee7fa9aceae4b).
- REPENTOGON [@7212bc5](https://github.com/TeamREPENTOGON/REPENTOGON/tree/7212bc54b6780c1a39f46b4229472f20a8826356):
  - `libzhl/functions/`: [RNG.zhl](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/libzhl/functions/RNG.zhl), [ItemPool.zhl](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/libzhl/functions/ItemPool.zhl), [ItemPool_Item.zhl](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/libzhl/functions/ItemPool_Item.zhl), [Room.zhl](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/libzhl/functions/Room.zhl), [RoomDescriptor.zhl](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/libzhl/functions/RoomDescriptor.zhl), [RoomSpawn.zhl](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/libzhl/functions/RoomSpawn.zhl), [RoomEntry.zhl](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/libzhl/functions/RoomEntry.zhl), [Global.zhl](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/libzhl/functions/Global.zhl) (`eRoomSpawnType`, `PoolItem`).
  - Lua bindings: [LuaItemPool.cpp](https://github.com/TeamREPENTOGON/REPENTOGON/blob/7212bc54b6780c1a39f46b4229472f20a8826356/repentogon/LuaInterfaces/LuaItemPool.cpp).
  - Docs: [ItemPool](https://repentogon.com/ItemPool.html) (`PickCollectible` differences), [ProceduralItemManager](https://repentogon.com/ProceduralItemManager.html), [StbGridType](https://repentogon.com/enums/StbGridType.html), [DealChance example](https://repentogon.com/examples/DealChance.html).
- EID [@993c881](https://github.com/wofsauge/External-Item-Descriptions/tree/993c881e0e52e08e1e8e87fcc068625961dcbd1a): [eid_itemprediction.lua](https://github.com/wofsauge/External-Item-Descriptions/blob/993c881e0e52e08e1e8e87fcc068625961dcbd1a/features/eid_itemprediction.lua), [eid_bagofcrafting.lua](https://github.com/wofsauge/External-Item-Descriptions/blob/993c881e0e52e08e1e8e87fcc068625961dcbd1a/features/eid_bagofcrafting.lua), [eid_api.lua](https://github.com/wofsauge/External-Item-Descriptions/blob/993c881e0e52e08e1e8e87fcc068625961dcbd1a/features/eid_api.lua) (`IsItemHidden`, `getObjectItemPool`), [main.lua](https://github.com/wofsauge/External-Item-Descriptions/blob/993c881e0e52e08e1e8e87fcc068625961dcbd1a/main.lua) (`IsAltChoice`), [eid_modifiers.lua](https://github.com/wofsauge/External-Item-Descriptions/blob/993c881e0e52e08e1e8e87fcc068625961dcbd1a/features/eid_modifiers.lua), [names/en_us.lua](https://github.com/wofsauge/External-Item-Descriptions/blob/993c881e0e52e08e1e8e87fcc068625961dcbd1a/descriptions/names/en_us.lua).
- MinimapAPI [@82b3134](https://github.com/TazTxUK/MinimapAPI/tree/82b313462408b4f0b588b6d3512c552715093c28): [data.lua](https://github.com/TazTxUK/MinimapAPI/blob/82b313462408b4f0b588b6d3512c552715093c28/scripts/minimapapi/data.lua), [main.lua](https://github.com/TazTxUK/MinimapAPI/blob/82b313462408b4f0b588b6d3512c552715093c28/scripts/minimapapi/main.lua), [resources/gfx/ui](https://github.com/TazTxUK/MinimapAPI/tree/82b313462408b4f0b588b6d3512c552715093c28/resources/gfx/ui).
- StageAPI [@9057387](https://github.com/Meowlala/BOIStageAPI15/tree/905738748f1c57998d468e90f219c8f0d4756a6a): [room/roomHandler.lua](https://github.com/Meowlala/BOIStageAPI15/blob/905738748f1c57998d468e90f219c8f0d4756a6a/scripts/stageapi/room/roomHandler.lua) (rock randomization), [room/layout.lua](https://github.com/Meowlala/BOIStageAPI15/blob/905738748f1c57998d468e90f219c8f0d4756a6a/scripts/stageapi/room/layout.lua) (`ForAllSpawnEntries`, `EntityInLevel`, shape sizes), [basic.lua](https://github.com/Meowlala/BOIStageAPI15/blob/905738748f1c57998d468e90f219c8f0d4756a6a/scripts/stageapi/basic.lua) (`CorrectedGridTypes`), [library/misc.lua](https://github.com/Meowlala/BOIStageAPI15/blob/905738748f1c57998d468e90f219c8f0d4756a6a/scripts/stageapi/library/misc.lua) (`VectorToGrid`).
- isaacscript [@72a71fa](https://github.com/IsaacScript/isaacscript/tree/72a71fa56e27fc62b78831f7a15c12429226bef8): `packages/isaacscript-common/src/functions/rooms.ts`, `roomData.ts`; `packages/isaac-typescript-definitions/src/types/classes/ItemPool.d.ts`.
- eden-seed-finder [@f8d46aa](https://github.com/2o181o28/eden-seed-finder/tree/f8d46aac86505193a3906bd9cea486bbcbabdc63): `eden.hpp` (`to_entity_seed`, `to_room_seed`), `item.hpp` (`get_collectible`, `pick_collectible`, pool shuffle), `rng.hpp`, `generator_baby_plum.cpp`, `main_baby_plum.lua`; Blade's [Eden gist](https://gist.github.com/bladecoding/5fcc1356bfb0cf26555b0ade7c4fedca) and [shift table gist](https://gist.github.com/bladecoding/17b341ed08ff94d2deb704ebda8ffc5f).
- Repentance API issue tracker: [#155](https://github.com/epfly6/RepentanceAPIIssueTracker/issues/155), [#323](https://github.com/epfly6/RepentanceAPIIssueTracker/issues/323), [#422](https://github.com/epfly6/RepentanceAPIIssueTracker/issues/422), [#610](https://github.com/epfly6/RepentanceAPIIssueTracker/issues/610).
- Wiki: [Rocks](https://bindingofisaacrebirth.wiki.gg/wiki/Rocks), [Ultra Secret Room](https://bindingofisaacrebirth.wiki.gg/wiki/Ultra_Secret_Room), [Boss Rush](https://bindingofisaacrebirth.wiki.gg/wiki/Boss_Rush), [Blue Womb](https://bindingofisaacrebirth.wiki.gg/wiki/Blue_Womb); [Steam thread on tinted rock generation](https://steamcommunity.com/app/250900/discussions/0/3714936444642700408) (speculative).
- Closed seed tools (claims only): [isaac.libido.cc](https://isaac.libido.cc/en/), [exchive Seed Analyser](https://exchive.com/games/the-binding-of-isaac/seed-analyser/). Mods: [Nayoh – First Item](https://steamcommunity.com/sharedfiles/filedetails/?id=2256570195).
- Local: vanilla `E:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\resources\scripts\main.lua` (read-only copy at `/wuxie/tmp/isaac-api-research-20261105/game-scripts/main.lua`); game logs `/wuxie/data/isaac-dodge/logs/runs/*.log.gz` (58 runs, v1.9.7.17.J460).
