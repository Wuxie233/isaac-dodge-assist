# Item stats and pills (Repentance+ v1.9.7.17.J460)

Goal: show, before the player commits, what a collectible does to the character's stats and what a pill on the floor will do, without ever changing game state (no `ItemPool` writes, no RNG draws, nothing that could desync Online lockstep). Vanilla Lua, no REPENTOGON. Researched 2026-11-05 against the user's install (`isaac-ng.exe` SHA-256 `210cade2…fb3ae4831`).

Labels as in [item-emulation.md](item-emulation.md): **[C]** confirmed in the game binary or data, **[C-log]** confirmed on saves or run logs, **[U]** inferred or untested.

## Verdicts

1. **`ItemPool:GetPillEffect(pillColor, player)` is a pure read [C].** It reads the colour→effect table and the player's items and hearts, and writes nothing that persists. It is also exactly what the game uses when a pill is swallowed. Its one side effect is that it fires `MC_GET_PILL_EFFECT`, so another mod's callback for that event would run (§2.3).
2. **`ItemPool:IsPillIdentified(color)` is a pure read [C].** It returns one byte.
3. **Recommended in-game approach:** for every pill pickup, call `GetPillEffect(pickup.SubType, player)` with the bound player, every frame or whenever the HUD redraws (§2.6). No emulation is needed. As a cross-check, the run-start shuffle was also reimplemented from the binary; it reproduces 14/14 colours on both saved runs [C-log] (§2.4).
4. **`item_stats.lua`** covers all 721 collectibles in `items.xml`: 293 have an entry, 163 of them with plain numbers. Of 34 items checked against the wiki, 32 matched; one was a parser bug, now fixed, and one was outdated EID text, now overridden (§1.5).
5. **`pill_effects.lua`** has all 50 PillEffects (0–49) with English and Chinese names: 23 good, 14 bad, 13 neutral.

## 1. Item stat effects

### 1.1 Sources

**External Item Descriptions (EID)**, `github.com/wofsauge/External-Item-Descriptions`, commit `993c881e` (2026-10-31).
- **Licence.** The repository has no LICENSE file and the GitHub API reports no licence. All rights are therefore reserved by default.
- **What is used.** The generator reads EID's markup and keeps only facts: numbers, stat kinds and flags. No description text is copied.
  - The comment after each row is the item's official game name.
  - EID's README credits the wiki and platinumgod as its own sources.

**Merge order.** EID on Repentance+ without REPENTOGON loads `descriptions/ab+/en_us.lua`, then applies `rep/en_us.lua`, then `rep+/en_us.lua` (`EID:updateDescriptionsViaTable`; `features/eid_language_manager.lua`). The generator merges them the same way. [C]

**Hearts** come from the game's own `items.xml`: the `maxhearts`, `soulhearts` and `blackhearts` attributes, in half hearts. They appear only on passive items, so they are pickup effects. [C]
- EID's "+N Health / Soul Hearts / Black Hearts" lines agree with these attributes for every item except Abaddon (230).
- Abaddon's 2 Black Hearts are given in code; for it, EID's value is used.

**Curated data:**
- **Weapon flags** come from a 16-item table. Each id is checked against EID's item name.
- **One Repentance+ override:** Odd Mushroom (Thin) (120) gives **+1.7 flat fire rate** in Rep+, not +1.7 tears. EID still has the Repentance text. Source: wiki "Tears" page, "Repentance+" marker.

**Character flag** comes from EID's `features/eid_conditionals.lua`: every `Add(Closest)PlayerConditional` with collectible ids, plus Birthright (619). It marks items whose effect differs for some character, for example Azazel overriding tear effects, or Keeper and Lost health items.

### 1.2 Parsing rules (`tools/gen_item_stats.py`)

**Description layout.** Each EID description is split at `#` into lines.

**Plain stat lines.** A line `↑/↓ {{Icon}} ±N Stat` or `xN Stat multiplier` becomes a field. Values add up; multipliers multiply.
- `Damage` → `dmg` / `dmgMult`
- `Tears` → `tears` (the tears-up stat)
- `Fire rate` → `fireRate` (flat). `Fire rate multiplier` and `Tears multiplier` → `tearsMult`.
- `Range` → `range` / `rangeMult`
- `Shot speed` → `shotSpeed` / `shotSpeedMult`
- `Speed` → `speed`
- `Luck` → `luck`

**Conditional.** Some stat lines set `conditional=true` and get **no number**. A line counts as conditional when it is:
- situational: it has a timer icon, "for the room", "when", "each", "%", "chance", "taking damage", "aura", "for the left/right eye", "wears off", and so on;
- under a header line ending in `:`, such as "Receive for the room:" or "Spending 3 coins grants either:". A bare "While held:" header is the exception.
- on an **active** item, which acts on use, unless the line says "while held";
- or it changes a stat without a plain number ("Damage up for every empty heart container", "Balances Isaac's stats").

**Flags:**
- `flight`, `spectral`, `piercing` and `homing` come from whole-line flags. On familiar items, such a line describes the familiar, so it is skipped unless it names Isaac.
- `random` marks random stat changes: Experimental Treatment, Dataminer, D8, Missing No., Void.
- `oneEye` marks stats for one eye only: Chemical Peel, The Peeper, Blood Clot, Eye Drops, The Scooper, Stye.

**Weapon flags** (curated):

| Flag | Items |
|---|---|
| `brimstone` | 118 |
| `laser` | 68, 152 |
| `knife` | 114 |
| `bombs` | 52 |
| `rockets` | 168 |
| `ipecac` | 149 |
| `ludovico` | 329 |
| `techx` | 395 |
| `lung` | 229 |
| `haemolacria` | 531 |
| `trisagion` | 533 |
| `sword` | 579 |
| `fetus` | 678 |
| `charged` (the attack must be charged) | 69, 114, 118, 229, 316, 395, 579, 678 |
| `tearDelayFormula` | 531: Rep's Haemolacria is "tear delay ×2 + 11", which EID's ×0.33 only approximates |

### 1.3 Field meaning and the fire-rate formula

- **`tears`** is the tears-up stat T, the "+0.7" of The Sad Onion. It is not tears per second. In Repentance, with T summed over all sources including the character's (wiki "Tears", Repentance rows):
  - T ≥ 0: tear delay = 16 − 6·√(1.3·T + 1), floored at 5 (reached at T = 1.816).
  - −0.77 < T < 0: tear delay = 16 − 6·√(1.3·T + 1) − 6·T.
  - T ≤ −0.77: tear delay = 16 − 6·T.
  - Fire rate = (30 / (delay + 1) + S) × P, where S is the sum of `fireRate` bonuses and P the product of `tearsMult`.
  - So `fireRate` items exceed the tears cap; `tears` items do not. Tear delay is no longer rounded in Repentance.
  - [U] beyond the wiki's text; this formula was not decompiled.
- **Old tear-delay rules.** The wiki also gives tear-delay forms for the "tears down" weapons: Brimstone ×3, Dr. Fetus ×2.5, Monstro's Lung ×4.3, Inner Eye and Mutant Spider ×2.1+3, Ipecac ×2+10. Repentance lists them as the fire-rate multipliers ×0.33, ×0.4, ≈×0.23, ×0.51, ×0.42 and ×1/3, which are what the table holds. Haemolacria alone keeps a pure tear-delay rule (`tearDelayFormula`).
- **`range`** uses Repentance units: tiles of travel, base 6.5, one "range up" = +1.5. AB+ values such as "+5.25 range" or tear height do not appear in the merged EID text.
- **Hearts** are full hearts: `hearts` = containers (empty ones included), `soul`, `black`, `bone`, `eternal`, `rotten`, `broken`. Health ups behave differently for Keeper, the Lost and soul-heart characters (EID handles this generically). That is not encoded except through the `character` flag on items EID special-cases.
- **`speedMin`** is "sets speed to at least N" while held (A Pony).
- **Non-additive rules that the table does not encode:**
  - Cricket's Head and Magic Mushroom ×1.5 do not stack with each other.
  - Odd Mushroom (Thin) ×0.9 applies only to "standard" damage ups.
  - Repeated copies give smaller bonuses (Odd Mushroom adds +0.7).
  - Sacred Heart's +1 is outside its ×2.3.

### 1.4 Coverage (`mod/isaac_dodge_assist/item_stats.lua`)

- 721 collectibles in `items.xml` (717 not hidden). All 721 have EID text.
- **293 entries** (an absent id means "no stat change"):
  - 163 with numbers: `dmg` 46, `hearts` 38, `speed` 31, `range` 30, `tears` 28, `shotSpeed` 20, `soul` 16, `tearsMult` 12, `dmgMult` 11, `black` 11, `luck` 10, `fireRate` 9, `rangeMult` 5, and a few others.
  - 122 with flags: `character` 91 (41 have nothing else), `flight` 10, `spectral` 8, `charged` 8, `oneEye` 6, `piercing` 5, `random` 5, `homing` 3, plus the 13 weapon kinds.
  - 81 conditional, 73 of them with no plain number.
- **Cross-checks** against `items.xml` `cache` flags (the stats the game re-evaluates on pickup) [C]:
  - Every emitted stat has a matching cache flag.
  - Every `flight` item has `flying`. The one item with `flying` and no flag is Recall (714), whose flight belongs to The Soul.
  - 14 items have a stat cache flag but neither numbers nor `conditional`. EID lists no plain pickup stat change for any of them, and they were not checked on the wiki:
    - Spoon Bender, Goat Head, Mom's Wig, Black Candle, Missing Page 2, Match Book, Kidney Stone, Parasitoid, Marbles, Flat Stone, Spirit Sword, Damocles, C Section, Decap Attack.
    - Their flags most likely come from tear effects, weapons or synergies [U].

### 1.5 Wiki cross-check (bindingofisaacrebirth.wiki.gg, 34 items)

Read with a crawler through the normal `/wiki/<page>` URLs (`?action=raw` is disallowed by robots.txt), plus the "Range" and "Tears" pages for version markers.

| Result | Items |
|---|---|
| Match | Sad Onion, Inner Eye, Cricket's Head, My Reflection, Number One, Magic Mushroom, Dr. Fetus, Rosary, The Pact, The Halo, Brimstone, Ipecac, Mutant Spider, Polyphemus, Sacred Heart, Guillotine, Cricket's Body, Mom's Perfume, Monstro's Lung, Death's Touch, Capricorn, Eve's Mascara, Soy Milk, Godhead, Dead Onion, Haemolacria, Eye of the Occult, Red Stew (conditional: wears off), Sausage, Glass Eye, Abaddon, Tractor Beam |
| Fixed: parser bug | Keeper's Sack (stats per 3 coins spent; now conditional, because every EID header is treated as conditional) |
| Fixed: EID outdated for Rep+ | Odd Mushroom (Thin): +1.7 flat fire rate in Rep+ (override) |

- **Sacred Heart and Godhead.** Their item pages list "+4.125 range" and "+1.2 range". The Range page marks both as pre-Repentance, with no range change in Rep/Rep+, which agrees with EID.
- **Rep+ changes.** The wiki's Rep+ change list (marked incomplete) names only 2Spooky (+0.5 fire rate, +0.2 shot speed), Revelation (no soul hearts) and Jupiter (heals 2). EID's rep+ file already has all three.

### 1.6 Limits

- EID can lag behind game patches (Odd Mushroom). Regenerate after an EID or game update, and re-check a sample.
- Conditional items carry no numbers by design. Trinkets, cards and pills are not covered by this table.
- Not parsed: multi-shot counts, tear size, Devil-chance changes, and the base stats and multipliers of characters (Azazel, Keeper and others).

## 2. Pills

### 2.1 Names and classes (`mod/isaac_dodge_assist/pill_effects.lua`)

**Source.** `pocketitems.xml` from `afterbirthp.a` has `<pilleffect id name class …>` for ids 0–49 [C].
- Its comment defines the class as a digit: 3 major, 2 medium, 1 minor, 0 joke.
- A trailing `+` marks a positive effect, `-` a negative one, and no suffix a neutral one.

**How the game stores the class** (loader 0x72dcda) [C]:
- The digit goes to `EffectClass` (config+0x4c).
- The sign goes to `EffectSubClass` (+0x4d): 1 "+", 2 "−", 0 none.

**Output.**
- `class` = good / bad / neutral (23 / 14 / 13) and `tier` = the digit.
- `ach` = the unlocking achievement. 28, 29 → 227; 30, 31 → 228; 43 → 321; 44 → 325; 45 → 324; 46 → 330.
- `nogreed` marks 19, 25 and 31.
- Names come from `stringtable.sta`, category PocketItems: English, and "Chinese (Simple)" (language id 13). All 50 have a Chinese name.

**Horse pills.** There are no separate horse entries or strings. `GetPillEffect` masks the colour with `& 0x7ff`, so a horse pill (colour | 0x800) has the same effect id, name and class as its base colour [C]. Only the magnitude differs; "×2" is a fair label for stat pills but not for every effect.

**Notable classes:**
- Bad Gas (0) is `1+` (good).
- Experimental Pill (49) is `3` (neutral).
- I'm Drowsy (41) and I'm Excited (42) are neutral, but PHD and False PHD swap them (§2.2).

### 2.2 `GetPillEffect`: bindings and logic

**Bindings.**
- The `ItemPool` Lua class is registered at 0x86d19e.
- `GetPillEffect` is registered by thunk 0x893690. Its Lua closure 0x8b6bd0 calls the native method 0x734a80 with ItemPool = `Game+0x1a740`.
- `IsPillIdentified` is registered by thunk 0x893750; its closure 0x8b6cf0 calls 0x83c490.

**The closure** takes the colour from `luaL_checkinteger(2)`; a nil argument 3 passes player = 0. The closure has no stores. [C]

**The game's own use.** At 0x7db7d8 the game calls `0x734a80(color, player)` and passes the result to `UsePill` 0x7c4180 (`push 0x980; push color; push eax`). So `GetPillEffect` returns exactly the effect a pill will have when used. [C]

**Native 0x734a80, step by step** [C unless marked]:

1. If `Game+0x2663c == 41`, return 4 (Explosive Diarrhea). This field is not `Game.Challenge` (+0x26584); what it holds is unknown. [U]
2. `eff = ItemPool[+0x7a4 + 4·(color & 0x7ff)]`. Colour 0 gives −1. There is no upper bound check.
3. **If a player was passed:**
   - **PHD mode** applies if the player has PHD (75), Virgo (303) or Lucky Foot (46), or the current Zodiac sign is Virgo (0x7c7960 returns 303).
     - Without False PHD (654), bad effects become good via the tables at 0xb6a240 → 0xb6a27c:
       6→7, 17→18, 13→14, 11→12, 15→16, 25→23, 1→2, 27→36, 29→28, 31→19, 37→23, 22→24, 39→40, 42→41, 47→48.
     - With False PHD as well, nothing is remapped.
   - **False PHD alone** turns good effects bad (jump table at 0x734c40):
     - {0, 7, 38}→6; {2, 5, 21}→1; {3, 16, 34}→15; {4, 12, 32}→11
     - {10, 18, 35}→17; {14, 20, 33}→13; 19→31; {23, 26}→25
     - 24→22; 28→29; 36→27; 40→39; 41→42; {43, 46}→44; 45→37; 48→47
   - **Health check `0x7c40e0(player, eff)`.**
     - Bad Trip (1) is kept only if the player's heart sum is above 2 half-hearts (above 16 in deathmatch). Otherwise it becomes Full Health (5), or I Found Pills (8) under False PHD.
     - Health Down (6) is replaced the same way, based on the player's health type. It becomes Health Up (7), or 8 under False PHD.
     - The exact heart fields are [U].
4. `r = 0x865ad0(eff, color & 0x7ff)` runs `MC_GET_PILL_EFFECT`. If `r ≠ −1`, then `eff = r`.

### 2.3 Purity evidence

**Call tree.** A Ghidra call-tree walk from 0x8b6bd0 and 0x734a80 to depth 6 listed every STORE (`ghidra/calltree_getpilleffect.txt`). On the reachable paths:

- **`HasCollectible` 0x7706e0** calls `RNG::RandomInt` only on a stack copy (`lea ecx,[ebp-0x14]` at 0x77094a and 0x770ac7). No persistent RNG advances. [C]
- **0x557b00** writes only its stack out-parameter. **0xa112c0** and **0x865ad0** write only the SEH chain (FS). [C]
- **Other functions with stores** (the 0x90c300 and 0x771550/0x740bc0 subtrees, the logger, the allocator) are reached only for collectible ids 313, 327, 328 and 9, or on error paths. 0x734a80 asks only for 75, 303, 46 and 654. [C]

**The callback.** 0x865ad0 enters Lua only if a mod registered `MC_GET_PILL_EFFECT`. In that case our call runs that mod's code, which could be impure.
- Vanilla `main.lua` exposes `Isaac.GetCallbacks(id)`, so the module can check `#Isaac.GetCallbacks(ModCallbacks.MC_GET_PILL_EFFECT) == 0` before calling.
- The installed EID does not register it. It calls `GetPillEffect(SubType, player)` itself for every pill it describes (`features/eid_api.lua`, `getAdjustedSubtype`).
- Our mod must never register it.

**`IsPillIdentified` (0x83c490)** is `return ItemPool[+0x7e0 + min(color & 0x7ff, 14)]`, with colour 0 giving index 0. It has no stores. [C]

### 2.4 How a colour gets its effect: the run-start shuffle

This is the pill part of `ItemPool::Init` (0x734f30), which runs right after the item pools load. [C]

1. **Seed.**
   - `S = X27^17(startSeed)` is stored at ItemPool+0x0. It is the same pool seed as in item-emulation.md §1.3.
   - "RNG A" lives at +0x654 with shift index 3 (triple 1, 9, 29).
   - Init makes one `Next()` and the pool loader makes two per pool (62). So the pill code starts from `X3^63(S)`, the same state that seeds the item pools' MT19937.
2. **Colours.** Start with `[1..13]` and run Fisher–Yates from the end: for i = 12 down to 1, `j = Next() % (i+1)`, swap. Then append 14 (gold).
3. **Effects.** Take the effect ids 0..49 in order, keeping those that pass `ItemConfig::PillEffect::IsAvailable` (0x730b20):
   - not in Greed if `greedmode="false"`;
   - deathmatch bans;
   - `Unlocked(achievement)`;
   - a global override [U] also passes the unlock check.

   Fisher–Yates this list the same way.
4. **Assign by slot.** Slot k of the shuffled colour list wants class `[3,3,3,3,2,1,0,−1,−1,3,2,1,−1,−1][k]` (bytes at 0x7353f8).
   - Take the first remaining effect of that class.
   - If the slot wants −1, or no effect of that class is left, take `pool[Next() % len]`.
   - Remove the chosen effect and store it at `ItemPool[+0x7a4 + 4·colour]`.
5. **Finish.** Set `pool[0] = −1` and clear all identified flags (`ItemPool+0x7e0`, 15 bytes).

**Later writers of the table:**
- **Gold pill (14).** After each gold pill is used, `UsePill` rerolls `pool[14]` through 0x736c30 and clears `identified[14]`. The new effect is drawn from effects not on colours 1–13, using the player's RNG. So `GetPillEffect(14)` always gives the *next* gold pill's effect. [C]
- **`ForceAddPillEffect` (0x736ba0).** If a colour already holds the effect, it returns that colour. Otherwise it overwrites `pool[RNG A % 13 + 1]`. Callers:
  - Magdalene's start, with achievement 332: Full Health and Health Up;
  - a challenge `startingpill` (only challenge 12 has one);
  - a payout entity with prizes 0x12/0x13, giving effects 33/32 (which entity is [U]);
  - Telepills spawn (0x71cf80);
  - the console's `giveitem p`;
  - Lua mods. [C]

**Identified flags.** Using a non-gold pill sets the flag (0x7c432a). PHD or False PHD on pickup identifies every colour (0x7617aa); so do Magdalene's start, `startingpill`, Telepills and Lua `IdentifyPill`. Amnesia clears them all (0x7c63ea). [C]

**A pill pickup's colour** is chosen by `GetPill` 0x734900 from the pickup's seed. It is a pure function of that seed:
- horse 1 in 70 when achievement 606 is unlocked;
- gold 1 in 140 when achievement 603 is unlocked. [C]

### 2.5 Validation

- **Saves [C-log].** `rep+gamestate1.dat` holds the ItemPool block: the pill array at block+0x3bb, with RNG A beside it.

  | Run | S | Colours | RNG A at end |
  |---|---|---|---|
  | 2FPCEKHY | 0xcde36708 | **14/14** | 0x56fc3ae1, equal |
  | QE2FFHVH | 0x34979414 | **14/14** | 0x6a519206, equal |

  - The QE2FFHVH copy was pulled read-only from Steam userdata, 2026-11-05 15:56.
  - Both runs used the local unlock state, with the six pill achievements locked. Treating every effect as unlocked gives a different assignment.
- **Run logs.** 59 logs under `/wuxie/data/isaac-dodge/logs/runs/` hold 109 `Action PillCard Triggered` lines in 6 runs. These are the input action only, with no colour or effect. The game logs nothing that names a pill, so the logs cannot validate pills.
  - To validate live, log `MC_USE_PILL(effect, player, flags)` (an observer callback) next to the colour shown on screen.

### 2.6 Recommended in-game approach

```lua
local pool = Game():GetItemPool()
-- player = the bound local player; for Tainted Forgotten's Soul use player:GetOtherTwin() (as EID does)
local safe = #Isaac.GetCallbacks(ModCallbacks.MC_GET_PILL_EFFECT) == 0   -- no other mod hooks the read
for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_PILL)) do
  local color  = e.SubType                                  -- PillColor, horse = color | 0x800
  local effect = safe and pool:GetPillEffect(color, player) or nil   -- -1/nil: unknown
  local horse  = color & PillColor.PILL_GIANT_FLAG ~= 0
  local known  = pool:IsPillIdentified(color)              -- optional: dim effects the player has not seen yet
end
```

- **Pass the player.** With player = nil the result is the raw table entry, without PHD, False PHD, Lucky Foot, Virgo or the heart checks.
- **Recompute on every render.** It is cheap and pure, and the answer changes when the player picks up PHD or False PHD, loses hearts, or after a gold pill is used.
- **Co-op.** The same colour can mean different effects for different players, for example when only one holds PHD. Show it for the bound player.
- **Fallback.** `/wuxie/tmp/isaac-stats-pills/pill_pool.py` gives the colour→effect table from the start seed and the unlock state (via `ItemConfig:GetPillEffect(id):IsAvailable()`). It does not follow `ForceAddPillEffect` or gold rerolls, so `GetPillEffect` is preferred.

## 3. Files and reproduction

**Generators:**
```
python3 tools/gen_item_stats.py <EID checkout> <dir with items.xml> mod/isaac_dodge_assist/item_stats.lua
python3 tools/gen_pill_effects.py <dir with pocketitems.xml and stringtable.sta> mod/isaac_dodge_assist/pill_effects.lua
```
- Both read only; neither executes EID code (it has its own Lua table reader).
- `gen_pill_effects.py` reuses `gen_item_names.py`'s string-table reader.
- Game XMLs and `stringtable.sta` come from `afterbirthp.a`, extracted in `%TEMP%` (text-and-fonts.md §4). Current copies are in `/wuxie/tmp/isaac-item-emulator/gamedata/rpp/`.

**Scratch** (`/wuxie/tmp/isaac-stats-pills/`):
- `dl/eid/`: the EID checkout.
- `pill_pool.py` and `validate_pills.py`: the shuffle model and the save comparison.
- `save/`: the pulled gamestate and persistent data.
- `ghidra/`: `DecompAt.java`, `DecompContaining.java`, `CallTreeStores.java`, `calltree_getpilleffect.txt`, and `out/*.c` with decompiles of:
  - 0x734a80, 0x8b6bd0, 0x83c490;
  - 0x734f30 (Init), 0x7c4180 (UsePill), 0x7c40e0, 0x7c7960, 0x7706e0, 0x865ad0;
  - 0x736ba0, 0x736c30, 0x734900, 0x730b20.
