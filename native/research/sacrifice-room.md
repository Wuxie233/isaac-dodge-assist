# Sacrifice room rewards before anyone sacrifices (Repentance+ v1.9.7.17.J460)

Goal: show what the next sacrifices on a sacrifice room's spikes give, in the room the players are in and in rooms not entered yet, and what Sanguine Bond's spikes give next. Pure reads only (Online lockstep: never call `RNG:Next()` on a game RNG, never spawn, never call `ItemPool`). Vanilla game, no REPENTOGON. Researched 2026-11-10 on the user's `isaac-ng.exe` (SHA-256 `210cade2…fb3ae4831`) and the 132 run logs, the same way as [room-feature-drops.md](room-feature-drops.md).

Labels: **[C]** read from the binary, **[C-log]** read from the binary and confirmed on the logs, **[U]** inferred or untested. Notation: `Xn(s)` is one xorshift step with shift index n (`X2` = (1,5,19), `X11` = (2,7,7), `X35` = (5,9,7)); `Xn^k` is k steps. Addresses are virtual addresses (image base 0x400000).

Module: `mod/isaac_dodge_assist/sacrifice_forecast.lua` (API at the top of the file; it includes `chest_forecast` for chest contents). Test: `lua native/tests/sacrifice_forecast_regression.lua [-v]`.

## Verdict

Everything a sacrifice gives is decided by the spike's own RNG, which Lua can read without touching it, and by the spike's sacrifice counter:

| What | Where | Lua read |
|---|---|---|
| Sacrifices made so far | `desc.VarData` (grid +0x18) | `spike.VarData` or `spike:GetSaveState().VarData` |
| The spike's RNG (shift X35) | grid +0x2c, copied to `desc.VariableSeed` (+0x20) after every sacrifice | `spike:GetRNG():GetSeed()` |
| A spike in a room not entered yet | RNG = `X35²(SpawnSeed)`, `SpawnSeed = X11^(i+1)(room SpawnSeed)` | `level:GetRoomByIdx(i).SpawnSeed`, layout index from the STB |

Sacrifice n (n = VarData + 1) advances the spike's RNG once: `s0 = X35(g)`, which becomes its new state. The rolls come from a copy `RNG(s0, shift 2)`: `t1 = X2(s0)` picks the case, `t2, t3, …` are the InitSeeds of what spawns. Neither the players' luck nor anything else in the run moves these numbers; the only context is the few conditions below.

| Check (logs 2026-11-04..09) | Result |
|---|---|
| Spike sprite variant `(X35(SpawnSeed) & 3) + 1` in the IAD GRID lines | **15 / 15** rooms |
| Logged pickups on the predicted sequence (sacrifices 1–16), right variant | **235 / 235** pickups in 12 rooms, 0 mismatches |
| — by sacrifice | 15 pennies (1st/2nd), 12 chests, 4 × 3 pennies, 6 × 30 pennies, 1 × 7 soul hearts, 4 soul hearts (7th), 4 angel items (7th) |
| Angel item pick seed = logged `MC_PRE_GET_COLLECTIBLE(pool 4, seed)` | **3 / 3** |
| Teleport (room transition type 3) right after a local sacrifice = predicted 6th | **1 / 1** |
| Stage transition right after a local sacrifice = predicted 12th+ Dark Room | **2 / 2** (stage 2 and stage 10 → stage 11) |
| Chest contents through `chest_forecast` (approximate context) | 11 / 12 opened chests fully seen |

Only the local player's sacrifices are logged (`IAD HIT flags=268435584`); a co-op partner's are not. The pickups' seeds show where the partner sacrificed in between; the test only requires a pickup's sacrifice number to be at least the local hits before it.

Not observed in the logs, read from the binary only [C]: the 1st/2nd sacrifice bomb rule, the angel chance bonuses (no log line), troll bombs, Uriel and Gabriel (a fight follows, but no spawn line), Redemption, and Sanguine Bond. EID's Sanguine Bond prediction uses the same formula and thresholds.

## 1. Where it is decided [C]

- `GridEntity_Spikes` vtable 0xb692c0. `Update` @0x71e9b0 hurts the players in reach through @0x70b170, which calls the per-entity handler @0x709fb0. In a sacrifice room (room type 13), or for spikes of variant ≥ 100, the damage flags are `DAMAGE_SPIKES | DAMAGE_NO_PENALTIES` (0x10000080).
- After the entity's `TakeDamage` (vtable +0x20) returns true, @0x70a309 checks all of the following. If any fails, nothing changes: VarData and the RNG stay as they were.
  - The grid is spikes (type 8).
  - The entity is a player, or familiar 3.62 (Isaac's Heart).
  - The damage has the spikes flag.
  - The room is a sacrifice room, or the spike's variant is ≥ 100.
  - The room's `RoomDescriptor.Flags` lack `FLAG_SACRIFICE_DONE` (1 << 2).
- It takes the player (the body for Tainted Soul) and calls `RNG::Next` (@0x7e90f0) on the spike's RNG at +0x2c, giving `s0`. It then increments `VarData`, builds the copy RNG `{s0, 1, 5, 19}` from the shift table entry 2 (@0xb1f4e0), and branches:
  - variant ≥ 100 (Sanguine Bond) → @0x70a3c6;
  - otherwise → jump table @0x70b140 on the old VarData (cases 0–10; 11 and up go to @0x70adf6).
- Every branch ends by copying the RNG state into `desc.VariableSeed`.
- Lua accessors:
  - `GridEntity.VarData` reads +0x18 (getter @0x67efc0);
  - `GridEntity:GetRNG` returns `this + 0x2c` (@0x85dda0);
  - the desc fields are Type +4, Variant +8, State +0xc, SpawnCount +0x10, SpawnSeed +0x14, VarData +0x18, Initialized +0x1c, VariableSeed +0x20 (base constructor @0x709c40).
- `RNG::RandomInt(n)` @0x7e9020 is `Next() % n`, and `RNG::RandomFloat` @0x7e9080 is `f32(f32(Next()) * 2.3283061589829401e-10f)`. `RNG::SetSeed` @0x7e8fe0 does not step the RNG.

## 2. The spike's seed [C-log]

Init (vtable[8] @0x71dfc0, at @0x71e11d) runs for type 8 with `variant % 100 == 0`, that is, an STB 1930 entry before its first load:

1. `r1 = X35(SpawnSeed)`
2. `variant += 1 + (r1 & 3)`: sprite variant 1–4, or 101–104.
3. If the desc is not yet `Initialized`: `VariableSeed = X35(r1)`.
4. Every load sets `RNG = (VariableSeed, X35)`.

A fresh spike therefore starts at `g0 = X35²(SpawnSeed)`, and revisits continue from the stored state. The layout spike's SpawnSeed is the usual `X11^(i+1)(room SpawnSeed)` for its 0-based index i in `desc.Data.Spawns`. The 13 sacrifice layouts in `00.special rooms.stb` have the spike at index 0, 2, 5, 0, 1, 12, 7, 4, 0, 4, 6, 4, 9 for variants 0–12.

## 3. Rewards by sacrifice number [C, outcomes with pickups C-log]

`t1 = X2(s0)`, `t2 = X2(t1)`, … Spawns are at a free position near (320, 340), with these InitSeeds.

| n | Roll | Result |
|---|---|---|
| 1, 2 | If game state flag 16 is set (Broken Shovel quest, see below) and player 1 has no bombs: `t1` is skipped | bomb 5.40.1 seed `t2` |
| 1, 2 | `t1 % 2 == 0` | penny 5.20.1 seed `t2`; otherwise nothing |
| 3 | `t1 % 2 == 0` | angel room chance +0.15 (`Level+0x182f4`, "You feel blessed!"); otherwise nothing |
| 4 | `t1 % 2 == 0` | chest 5.50.0 seed `t2`; otherwise nothing |
| 5 | `t1 % 2 == 0` | angel room chance +0.5 |
| 5 | otherwise | 3 pennies, seeds `t2..t4` |
| 6 | `t1 % 3 == 0` | teleport to the angel room (`InitializeDevilAngelRoom(true, false)`, `ChangeRoom(-1)`, transition 3) |
| 6 | otherwise | chest seed `t2` |
| 7 | `t1 % 3 == 0` | angel item: `ItemPool::GetCollectible(4, t3)` (removes it from the pool), pedestal seed `t2` |
| 7 | `t1 % 3 == 2`, devil deals > 0, stage < 7, Redemption still in the pools (@0x732d00) | Redemption 5.100.673 seed `t2` |
| 7 | otherwise | soul heart 5.10.3 seed `t2` |
| 8 | — | `Room+0x7230 = 35`: Room update spawns a troll bomb (4.3) every 5 frames, 7 in all, with `Random()` seeds |
| 9 | — | Uriel (271) seed `t1` |
| 10 | `t1 % 2 == 0` | 7 soul hearts, seeds `t2..t8` |
| 10 | otherwise | 30 pennies, seeds `t2..t31` |
| 11 | — | Gabriel (272) seed `t1` |
| ≥ 12 | `t1 % 2 == 0`, not Greed mode (Difficulty 2/3), the challenge's end stage allows it | Dark Room. On stage 11 type 0 (Dark Room) it is back to its starting room; elsewhere it is a stage transition to stage 11. Otherwise nothing |

- **Chests.** Chests spawn as 5.50.0, so `chest_forecast.resolve(50, seed)` gives the kind and `chest_forecast.predict` the contents (DropRNG = `RNG(seed, 30)`). All 12 logged chests stayed brown.
- **Pennies.** Pennies spawn with subtype 1. In run B78YY60D they showed up as 5.20.4: something in that run turned pennies into double pennies after spawning (likely Humbling Bundle) [U].
- **Flag 16.** The Lua enum calls it `STATE_SUPERGREED_SPAWNED`. The code that sets it (@0x806b08) is the Broken Shovel trigger: Basement I boss room cleared within 1800 frames; the start room then gets pickup 5.110 and effect 1000.115. Lua reads it with `game:GetStateFlag(16)`.
- **The 12+ check** (@0x70ae08) reads the challenge parameters (@0x706940). With no challenge it always passes; with a challenge, its end stage decides [U, `uncertain` in the module].

## 4. Sanguine Bond [C, thresholds agree with EID]

Sanguine Bond's spikes (variant 101–104) roll `f = RandomFloat(copy RNG)`, that is `f32(X2(X35(g)) · 2⁻³²)`:

| f | Result |
|---|---|
| < 0.15 | 6 pennies, seeds `t2..t7` |
| < 0.48 | the damage effect of collectible 692 on the player |
| < 0.58 | 2 black hearts 5.10.6, seeds `t2, t3` |
| < 0.63 | a collectible 5.100.0 seed `t2`, from the room's pool when it initialises (pick seed `X35(t2)` [U]) |
| < 0.65 | +3 Leviathan transformation counter |
| otherwise | nothing |

They do not use VarData.

## 5. Limits

- **Death and revive.** In run 84C0BJH9, three local sacrifices killed the player (revive transition type 6), and none of the predicted rewards (8th troll bombs onward) showed up. Whether a revive restores the room's spike state was not checked [U]. The module reads the live VarData and RNG, so it follows whatever the game kept.
- **Holy Mantle and the like.** A shield may make `TakeDamage` return false, and then there is no sacrifice [U]. The forecast just moves on with the next real one.
- **Redemption.** Whether the pools still hold Redemption needs the item emulator. Without it, the 7th's soul heart is reported as "soul heart or Redemption" whenever a devil deal was taken before stage 7.
- **Rooms not entered yet.** These rely on the layout index of the STB 1930 entry. A different variant of the same room shape would need its own index.
