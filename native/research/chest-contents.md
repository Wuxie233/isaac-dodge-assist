# Chest, sack and alt-rock contents before opening (Repentance+ v1.9.7.17.J460)

Goal: show what a chest, sack or alt rock on the floor will give before anyone touches it, from pure reads only (Online lockstep: never call `RNG:Next()` on a game RNG, never spawn or call `ItemPool`). Vanilla game, no REPENTOGON. Researched 2026-11-06 on the user's `isaac-ng.exe` (SHA-256 `210cade2…fb3ae4831`) and 131 run logs.

Labels as in [item-emulation.md](item-emulation.md): **[C]** read from the binary, **[C-log]** read from the binary and confirmed on the logs, **[U]** inferred or untested. Notation: `Xn(s)` is one xorshift `RNG:Next()` with shift index n; `Xn^k` is k steps.

Module: `mod/isaac_dodge_assist/chest_forecast.lua` (API at the top of the file). Test: `lua native/tests/chest_forecast_regression.lua`.

## Verdict

Feasible for every chest and sack, and for alt rocks. The outcome is a pure function of state the game exposes read-only:

- **Chests and sacks** roll on the pickup's own `DropRNG`, which `Entity::Init` seeds as `RNG(InitSeed, 30)` and nothing touches before opening. `pickup:GetDropRNG():GetSeed()` reads it. [C-log]
- **Alt rocks** roll on `RNG(desc.SpawnSeed, 35)`. `GridEntity:GetSaveState().SpawnSeed` reads it. [C-log]
- **Collectibles** inside chests are a normal `GetCollectible(pool, seed)` with a seed from the same chain, so `item_emulator.lua` resolves them. [C-log]
- **Subtypes** of the spawned pickups (penny or nickel, red or soul heart, …) come from `RNG(InitSeed, 35)` of each pickup, and the InitSeed of every chest pickup is known in advance. [C-log]

| Check (logs 2026-11-04..06) | Result |
|---|---|
| Opened chests and sacks: every logged pickup at its predicted chain position | **373 / 376**: brown 142/142, golden 90/90, red 50/50, sack 60/61, stone 18/20, spiked 12/12, eternal 1/1. The 3 misses held the Error trinket (§3) |
| Same, runs with no loot trinket ever picked up | 255 / 258 (the same 3 Error misses) |
| Chest collectibles through `item_emulator` with the replayed pool state | **66 / 66**: 25 golden-chest pool, 6 red-chest pool, 12 devil pool (Dark Room start room), 12 treasure pool (stage 11), 11 Tainted Isaac second items |
| Logged `GETCOL` seeds of chest picks at the predicted chain position and pool | all |
| Subtypes of the pickups those chests spawned | coins 373/373, keys 118/118, bombs 193/193, hearts 97/97, batteries 5/5, nested chests 4/4 |
| Sack Head replacements predicted / seen | 10 / 10 |
| Alt rocks whose drops appear in the logs (layout rocks only) | **9 / 9** (1 of them via "trinket not in the pool") |

No wooden, old, mega or Mom's chest was opened in the logs. Their trees are read from the binary only [C].

## 1. Where the outcome is decided

### 1.1 Opening paths [C]

| What | Function | Calls |
|---|---|---|
| Chest touched, key/bomb used | `Entity_Pickup::TryOpenChest` @0x6e6e40 (Lua `EntityPickup:TryOpenChest`, binding at 0x86a613) | `GetLootList(advance=1, player)` |
| Bomb chest hit by an explosion | `Entity_Pickup` damage handler @0x6edda0 | `TryOpenChest`; a mega chest first only counts down its subtype |
| Sack (69) touched | collision handler @0x6e8ae0 (call at 0x6ec583) | `GetLootList(advance=1, player)` |
| Guppy's Eye preview | `UpdatePickupGhosts` @0x6e17c0 | `GetLootList(advance=0, nearest player)` on a copy of the RNG |

`Entity_Pickup::GetLootList` @0x6dae40 builds the whole list. With `advance=0` it works on a copy of `DropRNG` (`uStack_a8`, a CMOVNZ at 0x6db062). That is the game's own pure preview; this module reproduces it in Lua.

The REPENTOGON snapshot's signatures for `GetLootList` (it matches 0x5832c0, unrelated) and for the `SelectRNG` ASM anchor do not fit this build. The addresses above were found through the `TryOpenChest` Lua binding.

### 1.2 The RNG [C-log]

- `Entity::Init` @0x6a93a0 stores `InitSeed = seed` (+0x3ec) and `DropRNG = RNG(seed, 30)` (+0x3dc).
- The binding `Entity:GetDropRNG` @0x4174b0 is `lea eax,[ecx+0x3dc]`, so it returns the live RNG; `RNG:GetSeed()` only reads it.
- In every one of the 373 replayed openings the RNG was untouched until opening. Room re-entry did not change it either: 38 opened containers were re-initialised by a revisit before they were opened.
- An eternal chest that closes again keeps the advanced state, so read `GetSeed()` and not `InitSeed`.
- `RandomInt(n)` @0x7e9020 is `Next() % n`.
- The weighted picker @0x49cbf0 takes a fresh `Next()` result r and lands on `X35(r) % totalWeight` (the shift triplet at 0xb1f66c) by cumulative weight in list order. Entries are not merged, so the order matters.

### 1.3 Spawning the list [C-log]

- **Entries.** Each entry is {type, variant, subtype, seed}; `TryOpenChest` spawns it with `seed` as the new entity's InitSeed and calls its `Update()` at once.
- **The first collectible.** The chest becomes the collectible: `Entity_Pickup::Morph` @0x6e30a0 without KeepSeed. The pedestal's InitSeed is `X7(chest InitSeed)` (66/66 logged pedestals). Later collectibles (mega chest) spawn with their entry seed.
- **Tainted Isaac.** A chest pedestal's second item is `GetCollectible(room pool, X38(pedestal InitSeed))`. That is the pool of the room it stands in (treasure in normal rooms, secret in secret rooms), not the chest pool [C-log 11/11].
- **Spawner.** The spawner is the chest. A nested container's chain is a suffix of its parent's chain, because its InitSeed is a value on the same xorshift-30 sequence.

### 1.4 Sack Head [C-log]

Code at 0x6e41b1, inside the pickup update. With Sack Head (424) in the party, a spawned key, bomb, coin, Lil Battery or card is checked once, on its first update, when:

- its price is 0, and
- it was not spawned by a sack, a player or a familiar.

It rolls `RandomInt(coin ? 10 : 5)` on its own DropRNG. On 0 it is removed and a sack spawns with seed `DropRNG.Next()`, that is `X30^2` of the pickup's seed. Loot from a sack is never replaced. 10 of 10 predicted replacements were seen.

## 2. GetLootList decision trees [C]

Common prelude, in order:

1. **Eternal chest (53).** Outside stage 11 and with subtype < 2 (it was reopened; a fresh eternal chest has subtype 2): `Next() & 3 == 0` gives an empty list.
2. **Pickup trinkets.** In the order Ace of Spades 45, Safety Cap 44, Child's Heart 34, Match Stick 41, Rusted Key 36. Each held one rolls `Next() % 100 < 33/66/100`, for a summed multiplier of 1/2/≥3. Child's Heart first needs `Next() % 5 == 0` when Daemon's Tail (22) is held. A trinket nobody holds costs no roll. A successful one adds one card/pill/bomb/heart/key (first in that list order) to every "pickups" outcome, seeded from its own RNG copy `RNG(seed, 2/3/4/5/6)`.
3. **Stage 11.** `cb = stage == 11` (Dark Room or The Chest) and not Greed (difficulty 2/3).
4. **Poker Chip (76).** `coin = X7(current state)` is even. The RNG does not advance.

Outcome tables (weights; pick = one `Next()`):

| Chest | Outcomes |
|---|---|
| **50 brown, 52 spiked, 54 mimic, 58 haunted** | trinket 10, chest 1, golden chest 1, pill 10, pickups 78 |
| **60 golden, 51 stone, 53 eternal** | trinket 10, chest 1, golden chest 1, card 10, **item from the golden chest pool (8) 20**, pickups 58 |
| with Gilded Key (159) | rich pickups 80, item 20 |
| **57 mega** | `RandomInt(2) == 0`: two treasure-pool items; else 5 rolls of {trinket 10, card 10, pickups 58} |
| any of the above in stage 11 | one item from the treasure pool (mega: two) |
| **56 wooden** | roll A {0:2, 1:10, 2:10} (only gates Lucky Toe), `n = Next() & 1 + 2`; roll B: item from the wooden chest pool (29) 2/22, n cards 10/22, n pills 10/22 |
| **55 old** | 1–3 soul hearts 43 (9 with Daemon's Tail), 3 trinkets 42, old chest pool (27) item 10, **angel** pool item 5 |
| **360 red** | red chest pool (9) item 10, teleport to the devil room 5 (not when the room index is −1 or −12), 2 spiders 13 (not when the opener's Left Hand multiplier is ≥ 3), mega troll bomb 13, 3 blue flies 7, 3 blue spiders 7, 1–2 soul hearts 15 (3 with Daemon's Tail), 2 troll bombs 15, 2 pills 15 |
| red, stage 11 start room | one **devil pool** item with GetCollectible flag 0x200, which refuses items tagged `devilsacrifice` (126, 157, 186, 225, 569, 672, 692, 695, 704) [C-log 12/12; 1 of them needed the exclusion] |
| **390 Mom's** | Red Key (580) until achievement 415, then a Mom's chest pool (15) item |
| **69 sack** | 2–3 rolls (`RandomInt(2) + 2`) of {bomb 15, key 20, coin 15, Lil Battery 4, card 4}. Each roll: pick, one discarded `Next()`, then the seed |
| black sack (subtype 2) | {bomb 15, black heart 10, bone heart 5, pill 15}; after a heart, black −10 and bone −5 |

"Pickups":

- **Count.** `n = max(2, RandomInt(golden-like ? 7 : 4))`, so brown chests give 2 (75%) or 3, golden ones 2–6.
- **Extra count.** Next comes the trinket bonus entry, then `RandomInt(3)` (always rolled): a non-zero result adds 1 with Lucky Toe (42). Mom's Key (199) doubles n. Poker Chip doubles n, or sets it to 0 (one fly) on a lost coin flip.
- **Each pickup.** Each of the n draws from {coins 35 (1–3 coins), heart 20 (4 with Daemon's Tail), key 15, bomb 30}.
- **Rich pickups.** Same, from {coins 25, heart 20, key 10, bomb 20, pill 5, card 5, rune 5, trinket 5, battery 5}.

Collectible entries are `entrySeed = Next()`, then `pickSeed = Next()`, then `GetCollectible(pool, pickSeed, noDecrease = !advance, 0, backup 0)`. A golden chest's item is therefore picked with `X30^3(InitSeed)` [C-log 25/25 logged GETCOL seeds]. With Poker Chip the item goes through @0x6ee640: a probe pick fixes quality q, and the real pick is restricted to quality q+1 (q when q > 2) [C, not seen in the logs].

## 3. Context that changes the outcome

| Input | Effect | Read in game (pure) |
|---|---|---|
| Trinkets 22, 34, 36, 41, 44, 45, 42, 76, 159, 61 | extra RNG rolls or other tables (§2). A wrong set shifts the whole chain | `player:HasTrinket`, `GetTrinketMultiplier` summed over players with `Variant == 0` |
| Error trinket (75) | imitates a trinket per room. `Player::HasTrinket` @0x771550 checks the imitated id (+0x2ef8) first, so `HasTrinket` sees it [C]. The 3 logged misses fit exactly one held pickup trinket [C-log] | `HasTrinket` |
| Mom's Key 199, Sack Head 424 | doubles counts / sack replacement | `HasCollectible` |
| stage, Greed, room index, start room index | stage 11 rules, red chest table | `level:GetStage()`, `game:IsGreedMode()`, `level:GetCurrentRoomIndex()`, `GetStartingRoomIndex()` |
| opening player | Left Hand (61) on red chests; Poker Chip in Deathmatch | the player who opens it |

Not readable in vanilla Lua and so passed by the caller: achievement unlocks (subtype gates, Mom's chest; see `M.UNLOCK_IDS`). The persistent-data byte for achievement a sits at offset 76 + a (sticky nickel 240, black sack 604, golden penny 613, wooden 609, haunted 611, mega 601 and Red Key 415 all agree). Every gate also accepts a second state, save mode 2 with a game flag, which is not identified [U]. Proxy for 415: `GetCollectible(580):IsAvailable()`.

## 4. Pickup subtypes (`M.resolve`) [C-log]

`Entity_Pickup::Init` passes InitSeed to the selector @0x6ddcd0, which rolls on `RNG(InitSeed, 35)`. For a pickup spawned with subtype 0:

- **Coin.** Nickel 1/20; else sticky 1/100 (ach. 240). Then dime 1/100; else lucky 1/100 (242). Golden 1/200 (613).
- **Heart.** Half 1/2, double 1/20 (1/50 in hard mode), rotten 1/50 (411), scared 1/100 (328), blended 1/100, eternal 1/50 (+ Bible Tract, Key Pieces), soul 1/10 (+ Mitre, Mom's Pearl, Eve) with half soul 1/4 (33), bone 1/20 (391), black 1/20 (+ Black Lipstick, Forgotten), gold 1/160 (224). Daemon's Tail forces black outside super secret rooms. Mom's Locket turns half hearts into full ones.
- **Key.** `pick({1:49, 2:1, (333 ? 4 : 1):1})`.
- **Bomb.** Double 1/7, golden 1/100 (226), mega troll 1/50, troll 1/10.
- **Battery.** Micro if (ach. 33 and `Next() % 3 ≠ 0`) or (hard mode and the next value is odd); mega 1/100, else golden 1/120 (615).
- **Sack.** Black 1/100 (604).
- **Random chest (5.50.0).** Mimic 1/40, red 1/20, stone 1/50, spiked 1/80, sack 1/100, wooden 1/80 (609), haunted 1/40 (611; plus a level check not modelled). Then eternal 1/1600; Left Hand makes it red, Gilded Key golden; a golden chest becomes mega 1/120 (601).
- **Post rules.** Humbling Bundle (only when InitSeed bit 15 is clear) and Bogo Bombs turn singles into doubles. With all players Tainted ??? bombs become poops.

Validation:

- Chest pickups: as in the table above. With normal difficulty hearts fall to 90/97 and batteries to 4/5, and without the save's unlocks coins fall to 372, batteries to 2 and hearts to 93. The user's Online lobbies therefore ran on hard, which the logs do not record.
- All logged coins (whatever spawned them): 1151/1168. The rest were spawned with an explicit subtype.
- Logged chests as random-chest spawns: 146/146 brown, 3/3 mimics and a few red, stone and spiked ones re-roll as logged; the others are explicit spawns (devil-room red chests, reward sacks).

Not modelled: pill colour, card or rune, and the trinket id; trinket 165's coin/key re-roll after stage 6; super secret room hearts; challenge overrides.

## 5. Alt rocks (`M.rock`) [C-log]

`GridEntity_Rock::Destroy` @0x7197d0 calls `SpawnDrops` @0x71b410 with `desc.SpawnSeed` (+0x14). The bindings are pure getters: `GridEntity:GetSaveState()` is `lea eax,[ecx+4]` (live desc, `.SpawnSeed` at +0x10), and `Room:GetBackdropType()` reads +0x1d18, the same field SpawnDrops uses.

The kind comes from `GetAltRockType(backdrop)` @0x718ee0:

| Kind | Backdrops |
|---|---|
| 2 mushroom | 4, 5, 6, 23, 32, 37, 46, 58, 59 |
| 3 skull | 7, 8, 9, 14, 16, 30, 33, 38–42, 47 |
| 4 polyp | 10–13, 34, 43, 44, 48 |
| 5 bucket | 31, 36, 45 |
| 1 urn | everything else |

Then, for one pass on chain `x_k = X35^k(SpawnSeed)`:

1. **Lucky Rock (15).** If held, it first takes `X35`, and on `% 3 == 0` one more step and a penny.
2. **Rare item.** `x_1 % 200 == 0`: a fixed item if `ItemPool::RemoveCollectible` (@0x733ff0) finds it not yet removed. Urn: Quarter 74. Mushroom: Wavy Cap 582 (secret room, 1/100), else Mini Mush 71 or Magic Mushroom 12. Skull: Dry Baby 265 or Ghost Baby 163. Polyp: Placenta 218 or Blood Clot 254 (Corpse: 26 or 268). Bucket: Leech 270 (Dross: The Poop 36). Sub-rolls take extra steps; a removed item falls through.
3. **Trinket.** `x % 40 == 0` on the next step: skull drops a black heart. The others drop a trinket if it is still in the trinket pool: Swallowed Penny 1 or Butt Penny 24 (Dross), Liberty Cap 32, Umbilical Cord 33 or Lil Larva 86 (Corpse). Otherwise the main roll follows.
4. **Main roll.** `RandomInt(10)`:
   - **1 or 3, bad:** spiders, gas, host, creep, or the bucket's spiders/leeches.
   - **2, good:**
     - mushroom: pill;
     - skull: card;
     - polyp: heart (rotten heart in the Corpse, ach. 411);
     - urn and bucket: `RandomInt(2) + 1` coins.

     These pickups use the next chain values as their InitSeeds, so their subtype is known too.
   - **anything else:** nothing.

The marked skull (26) drops The Fool (a pill with Little Baggy). The rare item, trinket and black heart get seeds from the global `Random()` @0x6eef60.

Validation:

- **Seeds.** The logged layout seed of a grid spawn (`IAD MAPCAL SPAWN`) is the rock's `SpawnSeed`: pickups appear at exactly `X35^4` (pill, card) and `X35^5/6` (coins).
- **Drops.** 9 of the 300 logged layout alt rocks left drops in the logs, and all 9 match. One of them rolled Liberty Cap, which was not in the pool, and dropped a pill at k4 instead.
- **Shares.** Over the 300 rocks: 33 good, 59 bad, 193 nothing, 13 trinket, 2 item, close to 10/20/68/2.5/0.5 %.
- **Not observable.** Rocks predicted "nothing" or "bad" leave no trace, and rocks that were never broken show nothing; neither is an error.

Not modelled: tinted and super special rocks, which also roll per-player trinket RNGs. The 3-pass case (`Player::HasCollectible(59)` on the destroyer) is [U]. The trinket-pool state is not readable: use the item config's availability and "not seen this run".

## 6. In-game reads

| Need | Read |
|---|---|
| Chest / sack | `p.Variant`, `p.SubType` (0 = opened), `p:GetDropRNG():GetSeed()`, `p.InitSeed` |
| Context | `CF.readContext(Game(), opener, unlocked)`: trinkets, collectibles, player types, stage, Greed, room and start index, room type, `game.Difficulty`. Unlocks come from the caller |
| Items | `item_emulator` state; `emu:predictRoom(picks, opts, true)` (current room's blacklist) |
| Alt rock | `g:GetType()` (6 or 26), `g:GetSaveState().SpawnSeed`, `room:GetBackdropType()`, `room:GetType()` |

## 7. Not modelled / open

- **Pickup identity.** Pill colours, cards and runes, trinket ids (trinket pool state), Poker Chip items (written but never observed), super secret room hearts, challenge and Deathmatch overrides, and trinket 165.
- **Unverified chest types.** Wooden, old, mega and Mom's chests have no logged opening. Haunted chest ghosts and mimic traps happen outside GetLootList.
- **Held trinkets.** The logs do not show drops or swaps. In game `HasTrinket` gives the truth.
- **Unlock state.** A second, unidentified unlock state in every achievement gate. These Online sessions behaved like the local save.
- **Nested containers.** Their contents can be predicted only once their variant has been rolled on spawn. `M.resolve` predicts that variant too, but unlock-gated kinds depend on `unlocked`.

## 8. Reproduce

```
cd <project>
python3 -I tools/gen_chest_forecast_cases.py /wuxie/data/isaac-dodge/logs/runs \
    native/tests/data/chest_forecast_cases.lua --emu-ref /wuxie/tmp/isaac-item-emulator
lua native/tests/chest_forecast_regression.lua
```

`--emu-ref` adds the item replay and the save's unlocks; without it those sections are skipped. Research scratch, including the Python references `chest_ref.py`, `rock_ref.py` and `subtype_ref.py`, the validators, and the Ghidra outputs in `ghidra/out/` (one `.c` file per address): `/wuxie/tmp/chest-forecast/`. The Ghidra 12.1.4 install is `/wuxie/tools/dev-tools/rea-backends/ghidra_12.1.4_PUBLIC` with JBR 25 from `/wuxie/tools/kotlin/kotlin-lsp-262.4739.0/jbr`. Run it headless and read-only on a copy of the item-emulator project with `/wuxie/tmp/chest-forecast/ghidra/run.sh`.
