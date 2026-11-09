#!/usr/bin/env python3
"""Generate native/tests/data/drop_forecast_cases.lua from the run logs, for
native/tests/drop_forecast_regression.lua (drop_forecast.lua replay).

    python3 -I tools/gen_drop_forecast_cases.py /wuxie/data/isaac-dodge/logs/runs \\
        native/tests/data/drop_forecast_cases.lua [--emu-ref /wuxie/tmp/isaac-item-emulator]

Only observations go into the file; the model is checked by the Lua test. The layout spawns come
from the "IAD MAPCAL SPAWN" lines (sensor before 0.25), each with the room it belongs to (the
"IAD MAPCAL ROOM" line that follows the block: ss = the room's SpawnSeed). Per run:

  poops     layout grid poops (STB 1490-1501): seed = the logged layout seed (the grid's
            SpawnSeed) and the pickups first initialised, after the spawn line, with a seed on the
            chain X1^k(seed), k <= 12. tr: pickup-relevant trinkets added before the first such
            pickup (+400 log lines: the "Adding trinket" line comes after the pickup animation),
            or before the end of the run when nothing dropped.
  fires     layout fireplaces (entity 33, which the room loader also makes from STB 1400/1410):
            pickups on X30^k(X35(seed)) (the DropRNG chain of the InitSeed), k <= 8.
  plates    pressure plates (4500): pickups on X35^k(seed), k <= 12.
  keepers   shopkeepers (17): pickups on X30^k(X35(seed)), k <= 40.
  slots     slot machines and beggars (6): pickups on X30^k(X35(seed)), k <= 80.
  rooms     every MAPCAL ROOM with its logged spawn seeds in log order (layout-seed check).
  stb       (with --emu-ref) runs without MAPCAL SPAWN lines (sensor 0.25+): each MAPCAL ROOM is
            matched to its layout in the extracted special.stb / basement.stb (same type, variant
            and spawn count, a single candidate; basement rooms only on stage 1-2 type 0). Every
            single-entry feature spawn i gives {t (STB code), v, i, ss} (slots: rv = the variant the
            "Spawn Entity" line shows, -1 if unmatched) and the pickups on the chain
            of the seed X11^(i+1)(ss) (grids) or its X35 (entities), as above.
  unlocked  (with --emu-ref) the subtype-relevant achievements of the save; trinketLocked: the
            trinkets of the poop / shopkeeper rolls whose achievement the save lacks.

See native/research/room-feature-drops.md.
"""
import argparse
import glob
import gzip
import os
import re
import struct
import sys

M32 = 0xFFFFFFFF
T1, T11, T30, T35 = (1, 5, 16), (2, 7, 7), (4, 3, 17), (5, 9, 7)
POOPS = set(range(1490, 1502))
TRINKETS = {2, 22, 24, 86, 91, 17, 18, 38, 87, 165}
COLLECTIBLES = {173, 203, 238, 239, 250, 251, 252, 236}
UNLOCKS = [33, 147, 224, 226, 240, 242, 328, 333, 391, 411, 415, 601, 604, 609, 611, 613, 614, 615]
ROLL_TRINKETS = [1, 2, 24, 49, 50, 51, 52]

R_INIT = re.compile(r'(?:\[Frame (\d+)\] )?Entity Pickup Initialized as: (\d+)\.(\d+)\.(-?\d+)\s+Seed: ([0-9a-f]+)')
R_SPAWN = re.compile(r'MAPCAL SPAWN t=(\d+) v=(\d+) s=(\d+) g=(\d+) seed=(\d+)')
R_MROOM = re.compile(r'IAD MAPCAL ROOM (\d+)\.(\d+) list=(-?\d+) ss=(\d+) as=(\d+) spawns=(\d+)')
R_LEVEL = re.compile(r'Level::Init m_Stage (\d+), m_StageType (\d+)')
R_ROOM = re.compile(r'\] - Room (-?\d+)\.(\d+)\(')
R_ADDC = re.compile(r'Adding collectible (\d+) ')
R_ADDT = re.compile(r'Adding trinket (\d+) ')
R_ENT6 = re.compile(r'Spawn Entity with Type\(6\), Variant\((\d+)\)')
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
        for n, line in enumerate(f):
            if 'Initialized as' in line:
                m = R_INIT.search(line)
                if m:
                    ev.append(('init', n, int(m[2]), int(m[3]), int(m[4]), int(m[5], 16)))
            elif 'MAPCAL SPAWN' in line:
                m = R_SPAWN.search(line)
                if m:
                    ev.append(('spawn', n, int(m[1]), int(m[2]), int(m[3]), int(m[5])))
            elif 'MAPCAL ROOM' in line:
                m = R_MROOM.search(line)
                if m:
                    ev.append(('mroom', n, int(m[1]), int(m[2]), int(m[4]), int(m[6])))
            elif 'Level::Init' in line:
                m = R_LEVEL.search(line)
                if m:
                    ev.append(('level', n, int(m[1]), int(m[2])))
            elif '] - Room ' in line:
                m = R_ROOM.search(line)
                if m:
                    ev.append(('room', n, int(m[1]), int(m[2])))
            elif 'Adding collectible' in line:
                m = R_ADDC.search(line)
                if m:
                    ev.append(('addc', n, int(m[1])))
            elif 'Adding trinket' in line:
                m = R_ADDT.search(line)
                if m:
                    ev.append(('addt', n, int(m[1])))
            elif 'Spawn Entity with Type(6)' in line:
                m = R_ENT6.search(line)
                if m:
                    ev.append(('ent6', n, int(m[1])))
            elif 'IAD RUN begin' in line or 'Spawning Co-Op Player' in line:
                m = R_RUN.search(line) or R_COOP.search(line)
                if m:
                    ev.append(('ptype', n, int(m[1])))
    return ev


def parse_stb(path):
    """STB1 room layouts: [(type, variant, [ [(t, v, s, weight), ...] per spawn ])]."""
    b = open(path, 'rb').read()
    assert b[:4] == b'STB1'
    n, off, out = struct.unpack_from('<I', b, 4)[0], 8, []
    for _ in range(n):
        rtype, variant, _sub = struct.unpack_from('<III', b, off)
        off += 13
        nl = struct.unpack_from('<H', b, off)[0]
        off += 2 + nl + 4 + 4
        ndoors = b[off - 1]
        nspawns = struct.unpack_from('<H', b, off)[0]
        off += 2 + 5 * ndoors
        spawns = []
        for _ in range(nspawns):
            ne = b[off + 4]
            off += 5
            ents = []
            for _ in range(ne):
                t, v, s_ = struct.unpack_from('<HHH', b, off)
                ents.append((t, v, s_))
                off += 10
            spawns.append(ents)
        out.append((rtype, variant, spawns))
    return out


def is_feature(t):
    return t in (33, 1400, 1410, 17, 4500, 6) or 1490 <= t <= 1501


def lua_list(xs_):
    return '{' + ','.join(str(x) for x in xs_) + '}'


def lua_rows(rows):
    return '{' + ','.join('{' + ','.join(str(x) for x in r) + '}' for r in rows) + '}'


def run_cases(ev):
    first = {}                       # pickup seed -> (line, variant, subtype), first sighting
    for e in ev:
        if e[0] == 'init' and e[2] == 5 and e[5] not in first:
            first[e[5]] = (e[1], e[3], e[4])
    addt = [(e[1], e[2]) for e in ev if e[0] == 'addt']
    addc = [(e[1], e[2]) for e in ev if e[0] == 'addc']

    def hits(seed, t, n, after):
        ch = chain(seed, t, n)
        out = []
        for s, k in ch.items():
            f = first.get(s)
            if f and f[0] > after:
                out.append((k, f[1], f[2], f[0]))
        return sorted(out)

    feats = {'poops': [], 'fires': [], 'plates': [], 'keepers': [], 'slots': []}
    rooms = []
    seen = set()
    stage, rtype = 1, 1
    block = []

    def flush(ss, rt=None, rv=None):
        if ss is not None:
            rooms.append((ss, rt, rv, [(s[2], s[3], s[5]) for s in block]))
        for s in block:
            line, t, v, sub, seed = s[1], s[2], s[3], s[4], s[5]
            key = (t, seed)
            if key in seen:
                continue
            seen.add(key)
            if t in POOPS:
                kind, h = 'poops', hits(seed, T1, 12, line)
            elif t == 33:
                kind, h = 'fires', hits(xs(seed, T35), T30, 8, line)
            elif t == 4500:
                kind, h = 'plates', hits(seed, T35, 12, line)
            elif t == 17:
                kind, h = 'keepers', hits(xs(seed, T35), T30, 40, line)
            elif t == 6:
                kind, h = 'slots', hits(xs(seed, T35), T30, 80, line)
            else:
                continue
            at = h[0][3] + 400 if h else 1 << 60
            tr = sorted({x for n, x in addt if n < at} & TRINKETS)
            co = sorted({x for n, x in addc if n < at} & COLLECTIBLES)
            feats[kind].append(dict(t=t, v=v, s=sub, seed=seed, ss=ss, stage=stage, rtype=rtype,
                                    tr=tr, co=co, hits=[x[:3] for x in h]))
        block.clear()

    for e in ev:
        if e[0] == 'level':
            stage = e[2]
        elif e[0] == 'room':
            flush(None)
            rtype = e[2]
        elif e[0] == 'spawn':
            block.append(e)
        elif e[0] == 'mroom':
            flush(e[4], e[2], e[3])
    flush(None)
    return feats, rooms


def stb_cases(ev, layouts):
    if any(e[0] == 'spawn' for e in ev):
        return []
    first = {}
    for e in ev:
        if e[0] == 'init' and e[2] == 5 and e[5] not in first:
            first[e[5]] = (e[1], e[3], e[4])
    addt = [(e[1], e[2]) for e in ev if e[0] == 'addt']
    addc = [(e[1], e[2]) for e in ev if e[0] == 'addc']
    out, stage, stype, rtype, ent6 = [], 1, 0, 1, []
    for e in ev:
        if e[0] == 'level':
            stage, stype = e[2], e[3]
        elif e[0] == 'room':
            rtype, ent6 = e[2], []
        elif e[0] == 'ent6':
            ent6.append(e[2])
        elif e[0] == 'mroom':
            line, rt, rv, ss, n = e[1], e[2], e[3], e[4], e[5]
            cands = [sp for f, sp in layouts.get((rt, rv), [])
                     if len(sp) == n and (f == 'special' or (stage in (1, 2) and stype == 0))]
            if len(cands) != 1:
                continue
            # runtime variants of the room's slots, in spawn order (the loader replaces locked kinds)
            slots = [j for j, ents in enumerate(cands[0]) if any(x[0] == 6 for x in ents)]
            runtime = dict(zip(slots, ent6)) if len(slots) == len(ent6) else {}
            for i, ents in enumerate(cands[0]):
                if len(ents) != 1 or not is_feature(ents[0][0]):
                    continue
                t, v = ents[0][0], ents[0][1]
                seed = ss
                for _ in range(i + 1):
                    seed = xs(seed, T11)
                if 1490 <= t <= 1501:
                    ch = chain(seed, T1, 12)
                elif t == 4500:
                    ch = chain(seed, T35, 12)
                else:
                    ch = chain(xs(seed, T35), T30, 80 if t == 6 else 40)
                h = sorted((k, first[x][1], first[x][2], first[x][0]) for x, k in ch.items()
                           if x in first and first[x][0] > line)
                at = h[0][3] + 400 if h else 1 << 60
                out.append(dict(t=t, v=v, rv=runtime.get(i, -1) if t == 6 else -1, i=i, ss=ss, stage=stage,
                                rtype=rt, room='%d.%d' % (rt, rv),
                                tr=sorted({x for n_, x in addt if n_ < at} & TRINKETS),
                                co=sorted({x for n_, x in addc if n_ < at} & COLLECTIBLES),
                                hits=[x[:3] for x in h]))
    return out


def main(logdir, out, emu_ref=None):
    lines = ['-- Generated by tools/gen_drop_forecast_cases.py from %s (do not edit).' % logdir,
             '-- runs[i]: run, types (player types), poops / fires / plates / keepers / slots:',
             '--   {t (STB code / entity type), v, s, seed (logged layout seed), ss (room SpawnSeed),',
             '--    stage, rtype, tr / co (relevant trinkets / collectibles added before the drop),',
             '--    hits {k, variant, subtype} on the feature\'s RNG chain}; rooms {ss, type, variant,',
             '--   spawns {t, v, seed} in log order}.',
             '-- unlocked / locked: subtype-relevant achievements of the save in --emu-ref;',
             '-- trinketLocked: trinkets of the poop / shopkeeper rolls the save has not unlocked.',
             'return {']
    if emu_ref:
        sys.path.insert(0, emu_ref)
        from savefile import achievements
        have, _ = achievements(os.path.join(emu_ref, 'save', 'current.dat'))
        lines.append('  unlocked = %s,' % lua_list(a for a in UNLOCKS if a in have))
        lines.append('  locked = %s,' % lua_list(a for a in UNLOCKS if a not in have))
        ach = {}
        items = open(os.path.join(emu_ref, 'gamedata', 'rpp', 'items.xml'), encoding='utf-8').read()
        for m in re.finditer(r'<trinket\b[^>]*>', items):
            tag = m.group(0)
            i, a = re.search(r'\bid="(\d+)"', tag), re.search(r'\bachievement="(\d+)"', tag)
            if i and a:
                ach[int(i[1])] = int(a[1])
        lines.append('  trinketLocked = %s,' % lua_list(t for t in ROLL_TRINKETS if t in ach and ach[t] not in have))
    layouts = {}
    if emu_ref:
        for f in ('special', 'basement'):
            path = os.path.join(emu_ref, 'gamedata', 'rooms', f + '.stb')
            if os.path.exists(path):
                for rt, rv, sp in parse_stb(path):
                    layouts.setdefault((rt, rv), []).append((f, sp))
    lines.append('  runs = {')
    totals = {}
    for path in sorted(glob.glob(os.path.join(logdir, '*.log.gz'))):
        ev = parse(path)
        feats, rooms = run_cases(ev)
        stb = stb_cases(ev, layouts) if layouts else []
        if not rooms and not any(feats.values()) and not stb:
            continue
        run = os.path.basename(path)[16:24]
        types = sorted({e[2] for e in ev if e[0] == 'ptype'})
        lines.append('    { run = "%s", types = %s,' % (run, lua_list(types)))
        for kind in ('poops', 'fires', 'plates', 'keepers', 'slots'):
            rows = feats[kind]
            totals[kind] = totals.get(kind, 0) + len(rows)
            lines.append('      %s = {' % kind)
            for f in rows:
                lines.append('        {t=%d,v=%d,s=%d,seed=%d,ss=%s,stage=%d,rtype=%d,tr=%s,co=%s,hits=%s},'
                             % (f['t'], f['v'], f['s'], f['seed'], 'nil' if f['ss'] is None else f['ss'], f['stage'], f['rtype'],
                                lua_list(f['tr']), lua_list(f['co']), lua_rows(f['hits'])))
            lines.append('      },')
        lines.append('      rooms = {')
        for ss, rt, rv, sp in rooms:
            if sp:
                lines.append('        {ss=%d,type=%d,variant=%d,spawns=%s},' % (ss, rt, rv, lua_rows(sp)))
        totals['rooms'] = totals.get('rooms', 0) + sum(1 for r in rooms if r[3])
        lines.append('      },')
        lines.append('      stb = {')
        for f in stb:
            lines.append('        {t=%d,v=%d,rv=%d,i=%d,ss=%d,stage=%d,rtype=%d,room="%s",tr=%s,co=%s,hits=%s},'
                         % (f['t'], f['v'], f['rv'], f['i'], f['ss'], f['stage'], f['rtype'], f['room'],
                            lua_list(f['tr']), lua_list(f['co']), lua_rows(f['hits'])))
        totals['stb'] = totals.get('stb', 0) + len(stb)
        lines.append('      },')
        lines.append('    },')
    lines.append('  },')
    lines.append('}')
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(' '.join('%s %d' % kv for kv in sorted(totals.items())), '->', out)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('logdir')
    ap.add_argument('out')
    ap.add_argument('--emu-ref', help='item emulator reference workspace (save unlocks, items.xml)')
    a = ap.parse_args()
    main(a.logdir, a.out, a.emu_ref)
