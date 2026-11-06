#!/usr/bin/env python3
"""Generate native/tests/data/chest_forecast_cases.lua from the run logs, for
native/tests/chest_forecast_regression.lua (chest_forecast.lua replay).

    python3 -I tools/gen_chest_forecast_cases.py /wuxie/data/isaac-dodge/logs/runs \\
        native/tests/data/chest_forecast_cases.lua [--emu-ref /wuxie/tmp/isaac-item-emulator]

Only observations go into the file; the model is checked by the Lua test. Per run:

  containers  every chest / sack the log shows closed (first "Entity Pickup Initialized as" line),
              with the context the log reveals (stage, devil room / floor start room, Mom's Key,
              Sack Head, pickup trinkets ever added before it) and every pickup later initialised
              with a seed on its DropRNG chain X30^k(InitSeed), k <= 160 ("got"; only inits in the
              frame where that seed first shows, and not in the container's own spawn frame).
              "onchain" lists the containers seen on that chain (nested chests / sacks).
              "getcol" maps chain positions of logged GETCOL seeds to their pool; "ped" is the
              collectible initialised with seed X7(InitSeed) (the chest turned into a pedestal).
  rocks       every layout alt rock (IAD MAPCAL SPAWN t=1002, sensor 0.24 logs) with the
              backdrop of its room (from Level::Init stage/stage type) and the pickups on its
              X35 chain (k <= 12).
  items       (with --emu-ref) the item-pool event stream of every run with a chest collectible,
              in the format of item_emulator_cases.lua, with {"chest", variant, subtype, seed,
              stage, roomFlag, roomType, item} and {"chestcycle", roomType, pedestalSeed, item}
              (Tainted Isaac's second item) where a chest pedestal appears. Unlock state and the
              non-chest picks come from the reference workspace (validate2.run_states,
              gen_tests.py rules), which reads the save backups there.

See native/research/chest-contents.md.
"""
import argparse
import glob
import gzip
import os
import re
import sys

M32 = 0xFFFFFFFF
T7, T30, T35 = (1, 21, 20), (4, 3, 17), (5, 9, 7)
CONTAINERS = {50, 51, 52, 53, 54, 55, 56, 57, 58, 60, 360, 390, 69}
TRINKETS = {22, 34, 36, 41, 42, 44, 45, 76, 159, 61, 17, 18, 38, 87, 151, 165}
COLLECTIBLES = {173, 199, 203, 238, 239, 250, 251, 252, 424}
UNLOCKS = [33, 224, 226, 240, 242, 328, 333, 391, 411, 415, 601, 604, 609, 611, 613, 615]
STAGE_BACKDROP = {(1, 0): 1, (1, 1): 2, (1, 2): 3, (1, 4): 31, (1, 5): 45,
                  (3, 0): 4, (3, 1): 5, (3, 2): 6, (3, 4): 32, (3, 5): 46,
                  (5, 0): 7, (5, 1): 8, (5, 2): 9, (5, 4): 33, (5, 5): 47,
                  (7, 0): 10, (7, 1): 11, (7, 2): 12, (7, 4): 34, (7, 5): 48,
                  (9, 0): 13, (10, 0): 14, (10, 1): 15, (11, 0): 16, (11, 1): 17}
ROOM_BACKDROP = {7: 23, 8: 23}

R_INIT = re.compile(r'\[Frame (\d+)\] Entity Pickup Initialized as: (\d+)\.(\d+)\.(-?\d+)\s+Seed: ([0-9a-f]+)')
R_GETCOL = re.compile(r'IAD MAPCAL GETCOL pool=(\d+) dec=(\w+) seed=(\d+)')
R_LEVEL = re.compile(r'Level::Init m_Stage (\d+), m_StageType (\d+)')
R_ROOM = re.compile(r'\] - Room (-?\d+)\.(\d+)\(')
R_ADDC = re.compile(r'Adding collectible (\d+) ')
R_ADDT = re.compile(r'Adding trinket (\d+) ')
R_SPAWN = re.compile(r'MAPCAL SPAWN t=(\d+) v=(\d+) s=\d+ g=(\d+) seed=(\d+)')
R_RUN = re.compile(r'IAD RUN begin continued=\w+ player=(\d+)')
R_COOP = re.compile(r'Spawning Co-Op Player \(ePlayerType = (\d+)\)')


def xs(x, t):
    x ^= x >> t[0]
    x ^= (x << t[1]) & M32
    x ^= x >> t[2]
    return x & M32


def chain(seed, t, n):
    d, x = {}, seed
    for k in range(1, n + 1):
        x = xs(x, t)
        d.setdefault(x, k)
    return d


def parse(path):
    ev = []
    with gzip.open(path, 'rt', errors='replace') as f:
        for line in f:
            if 'Initialized as' in line:
                m = R_INIT.search(line)
                if m:
                    ev.append(('init', int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5], 16)))
            elif 'GETCOL' in line:
                m = R_GETCOL.search(line)
                if m:
                    ev.append(('getcol', int(m[1]), int(m[3])))
            elif 'MAPCAL SPAWN' in line:
                m = R_SPAWN.search(line)
                if m:
                    ev.append(('spawn', int(m[1]), int(m[2]), int(m[4])))
            elif 'Level::Init' in line:
                m = R_LEVEL.search(line)
                if m:
                    ev.append(('level', int(m[1]), int(m[2])))
            elif '] - Room ' in line:
                m = R_ROOM.search(line)
                if m:
                    ev.append(('room', int(m[1]), int(m[2])))
            elif 'Adding collectible' in line:
                m = R_ADDC.search(line)
                if m:
                    ev.append(('addc', int(m[1])))
            elif 'Adding trinket' in line:
                m = R_ADDT.search(line)
                if m:
                    ev.append(('addt', int(m[1])))
            elif 'IAD RUN begin' in line or 'Spawning Co-Op Player' in line:
                m = R_RUN.search(line) or R_COOP.search(line)
                if m:
                    ev.append(('ptype', int(m[1])))
    return ev


def containers(ev):
    out, seen = [], set()
    stage, stype, rtype, roomno = 1, 0, 1, 0
    trinkets, colls = set(), set()
    for i, e in enumerate(ev):
        if e[0] == 'level':
            stage, stype, roomno = e[1], e[2], 0
        elif e[0] == 'room':
            rtype, roomno = e[1], roomno + 1
        elif e[0] == 'addt':
            trinkets.add(e[1])
        elif e[0] == 'addc':
            colls.add(e[1])
        elif e[0] == 'init' and e[2] == 5 and e[3] in CONTAINERS and e[5] not in seen:
            seen.add(e[5])
            if e[3] == 69 or e[4] >= 1:
                out.append(dict(i=i, frame=e[1], v=e[3], s=e[4], seed=e[5], stage=stage,
                                room=-1 if rtype == 14 else (0 if roomno == 1 else 1), rtype=rtype,
                                mk=199 in colls, sh=424 in colls, tr=sorted(trinkets & TRINKETS),
                                co=sorted(colls & COLLECTIBLES)))
    return out


def observe(ev, c):
    ch = chain(c['seed'], T30, 160)
    morph = xs(c['seed'], T7)
    first, got, onchain, getcol, ped = {}, [], [], {}, None
    for e in ev[c['i'] + 1:]:
        if e[0] == 'init':
            sd, fr = e[5], e[1]
            if sd in ch and e[2] == 5 and e[3] in CONTAINERS and (e[3] == 69 or e[4] >= 1) \
                    and all(o[0] != ch[sd] for o in onchain):
                onchain.append((ch[sd], e[3], e[4]))
            if fr == c['frame'] or (sd not in ch and sd != morph):
                continue
            first.setdefault(sd, fr)
            if first[sd] != fr:
                continue
            if sd == morph:
                if e[3] == 100 and ped is None:
                    ped = e[4]
            else:
                got.append((ch[sd], e[3], e[4]))
        elif e[0] == 'getcol' and e[2] in ch:
            getcol.setdefault(ch[e[2]], e[1])
    return got, onchain, getcol, ped


def backdrop(stage, stype, rtype):
    if rtype in ROOM_BACKDROP:
        return ROOM_BACKDROP[rtype]
    s = stage if stage % 2 == 1 or stage >= 9 else stage - 1
    return STAGE_BACKDROP.get((s, stype))


def rocks(ev):
    out, seen = [], set()
    stage, stype, rtype = 1, 0, 1
    pk = {}
    for e in ev:
        if e[0] == 'init':
            pk.setdefault(e[5], (e[3], e[4]))
    for e in ev:
        if e[0] == 'level':
            stage, stype = e[1], e[2]
        elif e[0] == 'room':
            rtype = e[1]
        elif e[0] == 'spawn' and e[1] == 1002 and e[3] not in seen:
            seen.add(e[3])
            bd = backdrop(stage, stype, rtype)
            if bd is None:
                continue
            ch = chain(e[3], T35, 12)
            hits = sorted((ch[s], v[0], v[1]) for s, v in pk.items() if s in ch)
            out.append(dict(seed=e[3], variant=e[2], backdrop=bd, rtype=rtype, hits=hits))
    return out


def lua_list(xs_):
    return '{' + ','.join(str(x) for x in xs_) + '}'


def lua_rows(rows):
    return '{' + ','.join('{' + ','.join(str(x) for x in r) + '}' for r in rows) + '}'


def item_runs(emu_ref):
    """Item-pool event streams (gen_tests.py rules) with chest pedestal expectations."""
    sys.path.insert(0, emu_ref)
    from isaacrng import X
    from emu import POOL_ID
    from validate2 import run_states, ROOM_POOL, NOKEEPER
    out = []
    for run, locked in run_states():
        if run['continued']:
            continue
        keeper = any(e['ev'] in ('add', 'trinket') and e['char'] == '店主' for e in run['events'])
        unav = set(locked) | (NOKEEPER if keeper else set())
        evs = run['events']
        # chest pedestals: X7(InitSeed) of every closed container of the run
        peds, seen_c = {}, set()
        stage, roomno, rtype = 1, 0, 1
        for e in evs:
            if e['ev'] == 'level':
                stage, roomno = e['stage'], 0
            elif e['ev'] == 'room':
                roomno += 1
                rtype = e['rtype']
            elif e['ev'] == 'pickup' and e['type'] == 5 and e['var'] in CONTAINERS and e['seed'] not in seen_c:
                seen_c.add(e['seed'])
                if e['var'] == 69 or e['sub'] >= 1:
                    flag = -1 if rtype == 14 else (0 if roomno == 1 else 1)
                    peds.setdefault(xs(e['seed'], T7), (e['var'], e['sub'], e['seed'], stage, flag))
        out_ev, seen, boss_done, nchest = [], {}, set(), 0
        for i, e in enumerate(evs):
            if e['ev'] == 'room':
                out_ev.append('{"room"}')
                continue
            if e['ev'] == 'add':
                out_ev.append('{"add",%d}' % e['item'])
                continue
            if e['ev'] != 'pickup' or e['var'] != 100 or e['sub'] == 0:
                continue
            subs = seen.setdefault(e['seed'], [])
            if e['sub'] in subs:
                continue
            subs.append(e['sub'])
            r, item, pool = e['room'], e['sub'], None
            if e['seed'] in peds:
                v, s, cseed, stg, flag = peds[e['seed']]
                rt = r['rtype'] if r else 1
                if len(subs) == 1:
                    out_ev.append('{"chest",%d,%d,%d,%d,%d,%d,%d}' % (v, s, cseed, stg, flag, rt, item))
                    nchest += 1
                elif len(subs) == 2:
                    out_ev.append('{"chestcycle",%d,%d,%d}' % (rt, e['seed'], item))
                    nchest += 1
                continue
            if r is not None and r['first'] and r['spawnseed'] is not None:
                if e['atload']:
                    pool = ROOM_POOL.get(r['rtype'], 0)
                    if r['rtype'] == 11:
                        pool = 2
                elif r['rtype'] == 5 and r['spawnseed'] not in boss_done:
                    boss_done.add(r['spawnseed'])
                    pool = 3 if 3500 <= r['variant'] < 3600 else 2
            if pool is None:
                for f in evs[i + 1:i + 4000]:
                    if f['ev'] == 'add' and f['item'] == item and f['pool'] in POOL_ID:
                        pool = POOL_ID[f['pool']]
                        break
            out_ev.append('{"remove",%d}' % item if pool is None else '{"pick",%d,%d}' % (pool, item))
        if nchest:
            out.append((run['seed'], sorted(unav), sorted(locked), out_ev))
    return out


def main(logdir, out, emu_ref=None):
    lines = ['-- Generated by tools/gen_chest_forecast_cases.py from %s (do not edit).' % logdir,
             '-- loot[run]: types (player types); containers[i]: v, s, seed, stage, room (-1 devil room,',
             '--   0 floor start room, 1 other), mk (Mom\'s Key), sh (Sack Head), tr / co (relevant trinkets /',
             '--   collectibles added before it), got {k, variant, subtype},',
             '--   onchain {k, variant, subtype}, getcol {k, pool}, ped (collectible at X7(seed)).',
             '-- rocks[i]: seed, variant, backdrop, rtype, hits {k, variant, subtype} on the X35 chain.',
             '-- items: item_emulator_cases.lua format plus {"chest", v, s, seed, stage, roomFlag, roomType, item}',
             '--   and {"chestcycle", roomType, pedestalSeed, item}.',
             '-- unlocked: the relevant achievements of the save in the --emu-ref workspace (save/current.dat).',
             'return {']
    if emu_ref:
        sys.path.insert(0, emu_ref)
        from savefile import achievements
        have, _ = achievements(os.path.join(emu_ref, 'save', 'current.dat'))
        lines.append('  unlocked = %s,' % lua_list(a for a in UNLOCKS if a in have))
        lines.append('  locked = %s,' % lua_list(a for a in UNLOCKS if a not in have))
    lines.append('  loot = {')
    nrock = []
    ncont = 0
    for path in sorted(glob.glob(os.path.join(logdir, '*.log.gz'))):
        ev = parse(path)
        run = os.path.basename(path)[16:24]
        rows = []
        for c in containers(ev):
            got, onchain, getcol, ped = observe(ev, c)
            if not got and not getcol and ped is None:
                continue
            ncont += 1
            rows.append('      {v=%d,s=%d,seed=%d,frame=%d,stage=%d,room=%d,rtype=%d,mk=%s,sh=%s,tr=%s,co=%s,got=%s,onchain=%s,getcol=%s,ped=%s},'
                        % (c['v'], c['s'], c['seed'], c['frame'], c['stage'], c['room'], c['rtype'],
                           str(c['mk']).lower(), str(c['sh']).lower(), lua_list(c['tr']), lua_list(c['co']), lua_rows(sorted(got)),
                           lua_rows(sorted(onchain)), lua_rows(sorted(getcol.items())), ped if ped else 'nil'))
        if rows:
            types = sorted({e[1] for e in ev if e[0] == 'ptype'})
            lines.append('    { run = "%s", types = %s, containers = {' % (run, lua_list(types)))
            lines.extend(rows)
            lines.append('    } },')
        nrock.extend(dict(r, run=run) for r in rocks(ev))
    lines.append('  },')
    lines.append('  rocks = {')
    for r in nrock:
        lines.append('    {run="%s",seed=%d,variant=%d,backdrop=%d,rtype=%d,hits=%s},'
                     % (r['run'], r['seed'], r['variant'], r['backdrop'], r['rtype'], lua_rows(r['hits'])))
    lines.append('  },')
    lines.append('  items = {')
    nitems = 0
    if emu_ref:
        for seed, unav, locked, evs in item_runs(emu_ref):
            nitems += sum(1 for x in evs if x.startswith('{"chest'))
            lines.append('    { seed = "%s", unavailable = %s, notUnlocked = %s,' % (seed, lua_list(unav), lua_list(locked)))
            lines.append('      events = {' + ','.join(evs) + '} },')
    lines.append('  },')
    lines.append('}')
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print('containers', ncont, 'rocks', len(nrock), 'chest item expectations', nitems, '->', out)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('logdir')
    ap.add_argument('out')
    ap.add_argument('--emu-ref', help='item emulator reference workspace (unlock state for the item replay)')
    a = ap.parse_args()
    main(a.logdir, a.out, a.emu_ref)
