# Room feature drops before anyone acts (Repentance+ v1.9.7.17.J460)

Goal: show what breaking a poop, putting out a fireplace, killing a shopkeeper, pressing a reward plate or paying a slot machine or beggar gives, before the players act, including in rooms not entered yet. Pure reads only (Online lockstep: never call `RNG:Next()` on a game RNG, never spawn or call `ItemPool`). Vanilla game, no REPENTOGON. Researched 2026-11-09 on the user's `isaac-ng.exe` (SHA-256 `210cade2…fb3ae4831`) and 132 run logs, the same way as [chest-contents.md](chest-contents.md).

Labels: **[C]** read from the binary, **[C-log]** read from the binary and confirmed on the logs, **[U]** inferred or untested. Notation: `Xn(s)` is one xorshift `RNG:Next()` with shift index n; `Xn^k` is k steps. `RandomFloat(r)` is `f32(f32(r) * 2.3283061589829401e-10f)`.

Module: `mod/isaac_dodge_assist/drop_forecast.lua` (API at the top of the file; it includes `chest_forecast`). Test: `lua native/tests/drop_forecast_regression.lua`.

## Verdict

Every feature here decides its drop on one RNG the game exposes read-only, and the decision does not depend on how or when the players act:

| Feature | RNG | Read in the room | Seed in a room not entered yet |
|---|---|---|---|
| Grid poop (all kinds) | `RNG(SpawnSeed, 1)` | `g:GetSaveState().SpawnSeed` | `X11^(i+1)(desc.SpawnSeed)` |
| Giga poop chunks | `X39^j(SpawnSeed)` of part 9, then X55 | the variant-9 part's SpawnSeed and State | not derivable (part 9 is made at load with a `Random()` seed) |
| Fireplace (entity 33, also STB 1400/1410) | DropRNG = `RNG(InitSeed, 30)` | `npc:GetDropRNG():GetSeed()` | `X35(X11^(i+1)(desc.SpawnSeed))` |
| Shopkeeper (entity 17) | DropRNG | `npc:GetDropRNG():GetSeed()` | `X35(X11^(i+1)(desc.SpawnSeed))` |
| Reward plate (grid 20 variant 1) | `RNG(SpawnSeed, 35)` | `g:GetSaveState().SpawnSeed` | `X11^(i+1)(desc.SpawnSeed)` |
| Slot machine / beggar (entity 6) | DropRNG, one serial stream of payments and payouts | `npc:GetDropRNG():GetSeed()`; beggars also a donation counter, rebuilt from `npc.InitSeed` | `X35(X11^(i+1)(desc.SpawnSeed))`, counter 0 |

`i` is the 0-based index of the layout spawn in `desc.Data.Spawns`. Pickups the features spawn take their InitSeed from the same chain, so their subtypes are known too (`chest_forecast.resolve`).

| Check (logs 2026-11-04..09) | Result |
|---|---|
| Logged layout spawn seeds = `X11^(i+1)(room SpawnSeed)`, i rising in log order | **8599 / 8599** seeds of 389 rooms |
| Layout poops with drops in the logs, every pickup at its predicted chain position | **38 / 38** (35 normal poops, 3 golden poops); 26 of them only with Petrified Poop held |
| Layout fireplaces with drops in the logs | **14 / 14** (10 normal, 4 red), all at `X30^3(InitSeed)` |
| Reward plates with drops in the logs | **1 / 1** (two bombs at `X35^4`, `X35^5`) |
| Subtypes of those pickups (save unlocks, hard mode) | **69 / 69** (poops 53, fireplaces 14, plate 2) |
| `DF.forLayout(STB code, room SpawnSeed, i)` = the in-room forecast | 127 poops, 191 fireplaces, 41 shopkeepers, 3 reward plates |
| Rooms not entered yet, rebuilt from the STB files (post-0.25 logs, 90 of 208 rooms matched): `forLayout(STB code, SpawnSeed, i)` | 104 features; **5 / 5** with drops match, subtypes 5/5 (2 blue fireplaces, STB 1400 and 1500 entries) |
| Fireplaces predicted to drop only on normal difficulty (28) that dropped | **0** (hard mode, as the chest study found) |
| Slot machines and beggars with pickups on their DropRNG chain, fitting a payment count | **10 / 10** machines, 23 pickups, subtypes 16/16; one more pickup after a room re-entry is unexplained (§5) |
| Slot kinds spawned from STB entries | 16 / 16 (one rotten beggar became a key master) |

No shopkeeper was killed in the logs, and no white, giga or charming poop was logged. Neither the slot machine (6.1), fortune teller, crane game, bomb bum, battery bum nor rotten beggar paid out. Their trees are read from the binary only [C].

The STB check uses the layouts extracted so far (`special.stb`, `basement.stb`). A logged room is matched to one with the same type, variant and spawn count when exactly one candidate exists; basement rooms only count on stage 1–2 type 0.

## 1. Poops [C-log]

### 1.1 Where it is decided

- `GridEntity_Poop` vtable 0xb68648. `Hurt` @0x715330 adds damage to `State` (0..1000). A second path @0x70c000 destroys a grid from its desc (callers 0x653070, 0x6670f0). Both call `SpawnDrops` @0x7178c0 once, when State reaches 1000, with `desc.SpawnSeed` (+0x14) and `desc.VarData == 1`.
- The number of hits is random: each hit adds `damage (+1 with 1 in 3, again for normal poops) × 250` (golden: `Random() % 75 + 50`, white 125, giga 20). That uses the global `Random()`, but the drop does not depend on it. The forecast holds however the poop is broken.
- `SpawnSeed` never changes, also across room revisits. `GridEntity:GetSaveState()` is the live desc (chest study §5).
- `GetVariant()`: 0 normal, 1 red, 2 corny, 3 golden, 4 rainbow, 5 black, 6 white, 7–10 giga parts, 11 charming. STB codes: 1500 → 0, 1490 → 1, 1495 → 2, 1496 → 3, 1494 → 4, 1497 → 5, 1498 → 6, 1499 → 7, 1501 → 11.

### 1.2 SpawnDrops @0x7178c0, chain `x_k = X1^k(SpawnSeed)`

Per-player RNGs come first, without touching the chain: `d1 = X11(seed)`, `d2 = X11(d1)`, `d3 = X11(d2)` pick the Daemon's Tail (22), Butt Penny (24) and E. Coli (236) holder (§5), only when someone holds them.

**Normal, corny, white (0, 2, 6).** Chance `c = 0.1f`. Butt Penny held: `c = max(0.1, m24 · 0.1 + 0.2)`. Petrified Poop held: `c = max(m2 · 0.1 + 0.4, c)`. VarData 1 (a poop a player made): `c = 0.01`. All in float32, m = summed trinket multiplier.

1. `x1`: drop if `c > RandomFloat(x1)`.
2. `x2 % 20 == 0` and Petrified Poop (trinket 2) still in the trinket pool: that trinket, seeded by `Random()`. Otherwise go on.
3. `x3`: heart if `RandomFloat(x3) < 0.25`, else a coin. Daemon's Tail turns the heart into a coin unless its holder RNG gives `Next() % 5 == 0`; Butt Penny then needs `Next() % 3 == 0`.
4. The pickup spawns with subtype 0 and **seed `x4`**. Its kind (penny, nickel, red/soul heart …) comes from `RNG(x4, 35)`.

Without a drop, E. Coli gives a second chance: holder `RandomFloat(Next()) < c`, then `x2` (needs `< 0.01` only for player poops), `x3 < 0.25`, the Daemon check, and a heart with seed `x4`.

**Golden (3).**

1. `x1 % 3 == 0` and Counterfeit Penny (52) still in the trinket pool: that trinket with seed `x2`. Nothing else drops.
2. Otherwise `n = x2 % 3 + 5` coins with seeds `x3 … x(n+2)`.

**Black (5).** Damages and slows nearby enemies. With Meconium (91), the first holder's multiplier gives chance 5 / 7 / 10 % on `x1 % 100`; a black heart with seed `x2`.

**Red (1)** drops nothing and regrows. **Rainbow (4)** heals every player fully. **Corny (2)** also spawns an eternal fly from its update (`Random()` seed, @0x715b20).

**Charming (11)** spawns a charmed dip per damage chunk (@0x716db0), not a pickup.

After any variant except red:

- Lil Larva (86) spawns blue flies.
- Brown Cap (90) makes an explosion.
- On the damage path, `X55(seed) & 1 == 0` gives a Book of Virtues wisp when the acting player global (0xc7ac6c) holds item 584.

The pass count is 3 instead of 1 when that same acting player holds the hidden collectible 59 [U, not seen]. Then the chance has a floor of 0.2 and golden poops drop `(x & 1) + 2` coins per pass.

### 1.3 Giga poop (parts 7–10) @0x716db0 [C]

The four parts pass their damage to part 9, which holds the State. Every 20 State points is a chunk, 50 chunks in all, and each chunk j that breaks rolls on `s_j = X39^j(seed of part 9)`:

1. `u = X55(s_j)`. Nothing happens unless `u & 1 == 0`.
2. The holder seeds are `X55(u)`, `X55²(u)`, `X55³(u)`.
3. `v = X55⁴(u)`: drop if `c > RandomFloat(v)`, with base `c = 0.25` and the same Butt Penny, Petrified Poop and player-poop rules as normal poops.
4. Then, as for normal poops on the X55 chain: Petrified Poop on `% 20`, heart below 0.25 (else coin), seed one step later.

Expected: about 6 pickups per giga poop. `DF.gigaPoop(seed, state, ctx)` lists the chunks still to break. An unvisited room cannot be forecast: part 7 comes from the layout, but parts 8–10 are made at load (@0x718ac0) with seeds from the global `Random()`.

### 1.4 Validation

- **Seeds.** The logged layout seed (`IAD MAPCAL SPAWN`) of a poop is its SpawnSeed: every logged drop sits at `X1^4` (normal) or `X1^3…` (golden), and nothing appears elsewhere on the 81 shift chains (scan, k ≤ 8).
- **Drops.** 38 of 127 layout poops left drops, and all 38 match: 27 coins, 8 hearts, and 5 / 6 / 7 coins from the three golden poops.
- **Petrified Poop.** 26 of the 38 drops need it held. Its "Adding trinket" line comes after the pickup animation, so the test counts trinkets added up to 400 lines after the drop.
- **Trinket pool.** One poop predicted Petrified Poop, and it appeared in that room. A later poop on `x2 % 20 == 0` gave a coin, because the trinket was taken by then. The golden poops rolled Counterfeit Penny but gave coins: the save lacks its achievement 64.
- **Not observable.** Poops predicted to drop that left nothing in the logs were not broken; neither is an error.

## 2. Fireplaces [C-log]

- AI @0x6d18d0 (NPC AI table at 0x6c41dc, type 33 → 0x6c3685). When the fire goes out (HP below the threshold, or water/bomb), it sets State 3 and calls the drop list @0x6d1580 with `advance = 1`, then spawns the list.
- The list rolls on the fireplace's **DropRNG**. Nothing else touches it before, so `npc:GetDropRNG():GetSeed()` = InitSeed until then.
- With Guppy's Eye (665), the game previews the same list with `advance = 0` (@0x6da530), the same pure preview chests have.
- **Not on this list.** White (4), movable (10, 12, 13) and coal (11) drop nothing, and so does a fireplace with entity flag bit 42 (+0x16c & 0x400; read `npc:HasEntityFlags(1 << 42)`). Room load sets it on some purple fireplaces (@0x7f4a55); its Lua enum name is not checked [U].

Tree (chain `y_k = X30^k(InitSeed)`; `c = 0.25`, **0.1 in hard mode**, `Game::IsHardMode` @0x6f8100):

| Variant | Roll |
|---|---|
| 0 normal, 1 red (and others) | `RandomFloat(y1) < c`: `RandomFloat(y2) < 0.25` → heart, else coin; seed `y3`. Daemon's Tail held: the heart needs `X4(y2) % 5 == 0` (a copy, the chain does not move), else a coin |
| 2 blue, 3 purple | `RandomFloat(y1) < c`: soul heart (black heart with Daemon's Tail multiplier ≥ 2) with seed `y2`; Daemon's Tail held: only when `X4(y1) % 5 == 0`. [C-log 2/2: two blue fires in an angel room, soul hearts at `y2`] |

**Seeds.** Layout fireplaces, also the ones the room loader makes from STB 1400 (→ 33.0) and 1410 (→ 33.1), have `InitSeed = X35(layout seed)`.

**Validation.**

- **Drops.** 14 of 191 layout fireplaces dropped, all at `y3` with the predicted kind: 6 hearts, 8 coins, subtypes 14/14.
- **Hard mode.** Hard mode predicts 20 drops and normal mode 48. None of the 28 normal-only fireplaces dropped, so these lobbies ran on hard.

## 3. Shopkeepers [C]

AI @0x6c2220 (type 17 → 0x6c3556). On death (+0x173) it builds the list @0x6c1ac0 with `advance = 1` on the **DropRNG**. Its init only uses `InitSeed % 9 + 1` for the sprite. With entity flag bit 42 the list is empty. Guppy's Eye previews it (@0x6da530). Chain `y_k = X30^k(InitSeed)`.

**Variants 0 shop, 1 secret room (hanging), 2 error room:**

1. `y1 % 100 == 0` and Steam Sale (64) still in the pools (`ItemPool::RemoveCollectible` @0x733ff0 removes it): that item, seed `y2`.
2. `y_next % 100 == 0` and Head of the Keeper (429) available: that item.
3. `y_next % 100 == 0`, an unidentified game-state gate, and Coupon (521) available: that item [U: gate].
4. `y_next % 3`: 1 → two spiders (85) with the next two seeds; 2 → two coins (subtype 0) with the next two seeds; 0 → nothing.

**Variants 3, 4 (special shopkeepers):**

1. `y1 & 127 == 0` and the room is not a boss room: **Greed** (entity 50) appears and fights.
2. `y2 & 31 == 0`: up to three tries of `{1, 24, 49, 50, 51, 52}[y % 6]` (Swallowed, Butt, Bloody, Burnt, Flat, Counterfeit Penny). The first one still in the trinket pool drops, with the next seed.
3. Otherwise `y3 % 3 ≠ 0`: a nickel (5.20.2) with seed `y4`.

Shares for normal keepers: about 33 % two coins, 33 % spiders, 33 % nothing, 1–2 % an item. Over the 41 logged keepers, the forecast gives 13 coins, 12 spiders and 16 nothing.

## 4. Reward plate [C-log]

`GridEntity_PressurePlate` vtable 0xb68620. Update @0x9833c0: a player stepping on a plate at State 0 sets State 3 and calls the trigger @0x984550. For variant 1 it builds `RNG(SpawnSeed, 35)`: chain `x_k = X35^k(SpawnSeed)`.

- **`x1` odd: ambush.** Enemies chosen by stage (and Greed mode), whose seeds come from the `x1` chain. The room closes. While the plate sits at State 4, the update calls the trigger again 4 frames after the room clears. With the same seed it ambushes again [U: how the waves end was not traced].
- **`x1` even:** `roll = x2 % 100`, then:

| roll | Outcome (seeds from `x3` on) |
|---|---|
| 0–4 | trapdoor (grid 17) when `Level` allows one (@0x74b5d0: stage < 8, plus rules [U]); otherwise as 5–9 |
| 5–9 | a **golden poop** (grid 14 variant 3) next to the plate with SpawnSeed `x3`; its coins follow §1.2 |
| 10 | a normal poop with SpawnSeed `x3` |
| 11 | a collectible (5.100.0) with InitSeed `x3`: pick seed `X35(x3)`, pool of the room |
| 12–29 | `x3 % 3 + 1` coins, seeds `x4…` |
| 30–49 | `x3 % 2 + 1` hearts |
| 50–69 | `x3 % 2 + 1` bombs |
| 70–79 | a chest with InitSeed `x3`: `{50 brown, 60 golden, 51 stone, 360 red}[x4 % 4]`; brown/golden re-roll on `RNG(x3, 35)`, contents on `RNG(x3, 30)` (chest_forecast) |
| 80–84 | slot machine (6.1, `x4` even) or fortune teller (6.3) with InitSeed `x3` |
| 85–89 | donation machine (6.8) with InitSeed `x3` |
| 90–99 | troll bomb (4.3) |

Validation: of the 3 layout reward plates, one was pressed. Its roll of 50 predicted 2 bombs at `x4`, `x5`, as logged.

## 5. Slot machines and beggars [C-log]

`Entity_Slot` (vtable 0xb64c50). A payment (touch) goes through @0x6627e0 (vtable[23]); the payout runs at the sprite's "Prize" event in `Update` @0x65d950 (jump table 0x662760); pickups spawn through @0x6657a0, one DropRNG `Next()` per copy as the InitSeed; a machine blown up drops through @0x663aa0.

- **One RNG, one stream.** Everything rolls on the machine's DropRNG (`RNG(InitSeed, 30)`, state saved and restored with the room, @0x7eeeb0 / @0x7ef420). A machine takes a payment only in state 1, and goes back to state 1 only once the payout has run, so payment rolls and payout rolls form one serial stream. Animation timing moves when the rolls happen, not their values.
- **Luck is never read** (@0x6627e0, @0x65d950, @0x6657a0, @0x663aa0).
- **What matters.** Difficulty, and the paying player's Lucky Foot (46), PHD (75), Poker Chip (76, its multiplier up to 3 copies per pickup), Keeper / Tainted Keeper, Tainted Lost or Lost with Birthright, golden key, golden bomb.
- **Not modelled** (the module returns `unsupported`): Karma (85) adds rolls at payment, and Daemon's Tail (22) rolls on the player's trinket RNG.
- **Global `Random()`** is used only for the blood machine's Child's Heart seed, effects and spider seeds.
- **The donation counter** of beggar-type machines (4, 5, 13, 18, +0x420) is not readable in Lua. It starts at 0 and is saved with the room, so `DF.slotCounter` replays the payments from `InitSeed` until the DropRNG state matches.

Trees (`ri(n)` = `Next() % n`; hard = difficulty 1, blood donation also 3):

| Variant | Per payment | Payout |
|---|---|---|
| 2 blood donation | no roll | `ri(100)==0`: Child's Heart (34) if in the pool, seed `Random()`. Else `ri(15)==0`: IV Bag 135, or Blood Bag 119 when `ri(2)==0` or IV Bag is gone (achievement 147); the machine breaks. Else coins: hard 1 (`max(1, ri(2))`), normal `max(1, ri(3))`, +1 with PHD; Keeper `ri(2)`. Hard: 4 Nexts per payment |
| 4 beggar, 5 devil beggar | `counter += 1`; `thr = ri(4)+ri(4)+ri(2)`, at least 5 on hard; pays when `counter > thr`, then `counter = ri(2)+2` (+1 Lucky Foot) | Beggar: heart / key / bomb, or card, or food (22+`ri(5)`), or an item from pool 10 (spawn seed, then pick seed); food and item make it leave. Devil beggar: pill or card, `ri(4)==0` a trinket, else an item from pool 11 and it leaves. Hard: the first prize comes on payment 6–8 |
| 13 battery bum, 18 rotten beggar | `thr = ri(3)+ri(2)`, at least 2 on hard; the payout resets the counter to 0 | Battery bum: `ri(16)==0` item from pool 14 (pick seed first), else `ri(8)==0` AAA Battery / Watch Battery / a battery, else a charge. Rotten beggar: `ri(24)==0` item from pool 30, else `ri(4)==0` bone heart (391) / rotten heart (411) / trinket, else blue flies or spiders |
| 7 key master | `ri(100)`; pays below 35, always with a golden key | `ri(8)==0` (or golden key): Paper Clip or an item from pool 13, then it leaves; else a chest {50, 60, 360}[`ri(3)`] |
| 9 bomb bum | `ri(100)`: <25 coins, <35 heart, <40 item (golden bomb: item) | `ri(3)+1` coins, a heart, or an item from pool 25 (leaves) |
| 1 slot machine | `N%50==0` breaks; `p = N%21+3` (`N%15+3` with Lucky Foot or a Poker Chip roll), adjustments; hard: `(N&1)==0` gives nothing | 3 fly / pretty fly, 4 bomb, 5–6 heart, 7 key, 8 pill, 9 A Dollar, 10 Portable Slot (both break it), 11–13 coins. Hard: about 74 % nothing |
| 3 fortune teller | `RandomFloat < 0.85` on hard (0.65 normal; ×0.46 with Lucky Foot) gives only a fortune | breaks 1/20, Crystal Ball 1/30, card, soul heart, trinket |
| 16 crane game | prize pre-picked from pool 23 with the current state; `N%100 < 25` wins | the prize; three wins empty it |

Explosion (@0x663aa0): blood donation `ri(2)+1` times coins or a heart; devil beggar and hell game two spiders (`Random()`); the rest the default branch (1 in 5 a trinket or pill, rare chests, else 2–3 rolls of coins / heart / key / bomb).

**Seeds.** Machines from the layout: `InitSeed = X35(layout seed)`, counter 0. The room loader replaces locked kinds: a rotten beggar (STB 6.18) spawned as a key master in a save without achievement 614 [C-log 1; replacement code not read]. `DF.slotVariant` applies that rule, and `forLayout` forecasts the next 12 payments.

**Validation.**

- **Machines.** 10 machines left pickups on their DropRNG chain, and each fits a number of payments, with or without being blown up afterwards. That number is not logged, so the test searches it:
  - two blood donation machines with 4 payments each: coins at `k` 4/8/12/16, then a Blood Bag;
  - three beggars: 18 and 10 payments, and one blown up before any payment;
  - two devil beggars (10 and 7 payments);
  - a key master with a golden key;
  - a blood machine and a key master (the replaced rotten beggar) blown up in a super secret room.
- **Items.** The beggar (pool 10 → 54), devil beggar (11 → 420) and key master (13 → 511) items reproduce in the item emulator from the predicted pick seeds.
- **Unexplained [U].** Devil beggar 3936974190: after the players left and re-entered the room, its next pickup fits only with one extra `Next()` and the counter at 0, though the save code keeps both. It is the only re-entry case in the data.

Research and the Python reference: `/wuxie/tmp/drop-forecast/slots/` (`NOTES.md`, `slots_ref.py`, `slots.lua` with 1975 parity vectors; the module's port matches them all).

## 6. Context and per-player RNGs

| Input | Effect | Read in game (pure) |
|---|---|---|
| Petrified Poop 2, Butt Penny 24 (summed multipliers) | poop and giga chunk chance | `GetTrinketMultiplier` over players with Variant 0 |
| Daemon's Tail 22 | heart → coin (poops), soul → black heart / no drop (fires) | as above |
| Meconium 91 | black poop black heart (first holder's multiplier) | as above |
| Daemon's Tail / Butt Penny / E. Coli holder RNG | extra rolls in poops | `p:GetTrinketRNG(22/24):GetSeed()`, `p:GetCollectibleRNG(236):GetSeed()` per player |
| trinket pool state (2, 52, keeper trinkets) | trinket or fall-through | not readable: config `IsAvailable` and "not seen this run" |
| items still in pools (64, 429, 521) | keeper items | `item_emulator` `emu:isRemoved` |
| hard mode | fireplace odds, pickup subtypes | `game.Difficulty` 1 or 3 |
| stage, room type | trapdoor rule, boss-room Greed, subtypes | `level:GetStage()`, `room:GetType()` |

- **Choosing the holder.** When several players hold one of those items, @0x9be3e0 / @0x9be140 walk the players with Variant 0 in order, advance `X22` once per holder from the derived seed, and take the holder with the largest `RandomFloat`.
- **Their RNGs.** Those holder RNGs are the players' own trinket / collectible RNGs. The game constructs RNGs with shift 35 by default (@0x7e8f70), and the module assumes 35 for these [U].
- **Not validated.** None of these items were held in the logs.

## 7. In-game reads (all pure)

| Need | Read |
|---|---|
| Poop | `g:GetType() == 14`, `g:GetVariant()`, `g.State` (1000 = gone), `g:GetSaveState().SpawnSeed`, `.VarData` |
| Giga poop | the variant-9 part: SpawnSeed and State |
| Fireplace / shopkeeper | `npc.Variant`, `npc:GetDropRNG():GetSeed()`, `npc:HasEntityFlags(1 << 42)`, alive / burning (HitPoints > 1) |
| Reward plate | `g:GetType() == 20`, `g:GetVariant() == 1`, `g.State == 0`, `g:GetSaveState().SpawnSeed` |
| Slot / beggar | `npc.Variant`, `npc:GetDropRNG():GetSeed()`, `npc.InitSeed` (counter replay), `DF.payerContext(player)`, `game.Difficulty` |
| Context | `DF.readContext(Game(), unlocked)` (chest_forecast's context plus trinkets 2, 22, 24, 86, 91 and the holder RNG seeds) |
| Unvisited room | `desc.SpawnSeed`, `desc.Data.Spawns:Get(i)` entries (STB code, variant): `DF.forLayout(t, v, desc.SpawnSeed, i, ctx)` |

Collectibles (reward plate roll 11) go to `item_emulator`: `{Emu.poolForRoom(roomType), r.items[1].pickSeed}`.

## 8. Not modelled / open

- **Slots.** Karma and Daemon's Tail with machines; the slot loader's replacement rule beyond the rotten beggar; the devil beggar re-entry case; slot machine, fortune teller, crane, bomb bum, battery bum and rotten beggar payouts have no log case.
- **Layout choice.** For spawns with several weighted entries, which entry the room picks is not modelled, and neither are the loader's stage-based replacements (a code at 0x7ed4b8 swaps 1 in 10 entries for red poop, spikes, pits or fireplaces by stage) [U]. `forLayout` trusts the STB code it is given.
- **Pickup identity.** Trinket identities from the pool, and pill, card and rune kinds, as in the chest study.
- **Ambush waves** after a reward-plate ambush; whether the plate ever pays out then [U].
- **Coupon gate** (shopkeepers) [U]; the trapdoor rule beyond stage < 8 [U].
- **Rare paths.** The three-pass case (hidden item 59 on the acting player) and the Book of Virtues wisp on poops [U].
- **Player-made poops.** Their SpawnSeed is read in game as for any poop, but cannot be known before they exist.

## 9. Logging that would help (for the sensor)

Small, observation-only lines; each lets the test match a drop to the moment it happened instead of searching chains:

```lua
-- on MC_POST_NEW_ROOM, first visit or not: one line per standing feature
-- IAD FEAT g=<gridIndex> t=14 v=<variant> st=<State> ss=<SpawnSeed> vd=<VarData>      (poops, plates t=20)
-- IAD FEAT e=<InitSeed> t=<Type> v=<Variant> d=<GetDropRNG():GetSeed()> hp=<HitPoints>  (33, 17, 6)
for i = 0, room:GetGridSize() - 1 do
  local g = room:GetGridEntity(i)
  local t = g and g:GetType()
  if t == 14 or (t == 20 and g:GetVariant() == 1) then
    local d = g:GetSaveState()
    Isaac.DebugString(("IAD FEAT g=%d t=%d v=%d st=%d ss=%d vd=%d"):format(i, t, g:GetVariant(), g.State, d.SpawnSeed & 0xFFFFFFFF, d.VarData))
  end
end
-- per update (cheap: only on change): a poop reaching State 1000, a plate leaving State 0,
-- a fireplace whose HitPoints drop to <= 1, a shopkeeper that IsDead(), a slot whose DropRNG seed
-- changed: "IAD FEATX <same key> st=<new State> d=<new DropRNG seed> frame=<frame>"
-- plus, for slots, the paying player's coins/keys/bombs/hearts at that moment (one line per
-- payment fixes the payment count the test now has to search, and the re-entry case).
```

## 10. Reproduce

```
cd <project>
python3 -I tools/gen_drop_forecast_cases.py /wuxie/data/isaac-dodge/logs/runs \
    native/tests/data/drop_forecast_cases.lua --emu-ref /wuxie/tmp/isaac-item-emulator
lua native/tests/drop_forecast_regression.lua        # -v lists every matched drop
```

`--emu-ref` adds the save's unlocks (subtypes, locked trinkets); without it the subtype check treats gated kinds as locked. Research scratch: `/wuxie/tmp/drop-forecast/` (Python references `py/poop_ref.py`, `py/fire_ref.py`, validators, chain scans, `ghidra/out/` decompiles by address, `fn.sh` disassembly). Ghidra 12.1.4 headless as in the chest study, on a copy of its project (`ghidra/run.sh`).
