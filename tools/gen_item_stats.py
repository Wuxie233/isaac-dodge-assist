#!/usr/bin/env python3
"""Generate mod/isaac_dodge_assist/item_stats.lua: the plain stat changes each collectible gives on pickup.

    python3 tools/gen_item_stats.py <External-Item-Descriptions checkout> <dir with items.xml> mod/isaac_dodge_assist/item_stats.lua

Sources (see native/research/stats-and-pills.md):
- Stats and flags are *derived* by parsing the English text of External Item Descriptions
  (github.com/wofsauge/External-Item-Descriptions, the repo has no licence file, so no text is
  copied; only numbers and flags read from its markup end up in the output). EID loads
  descriptions/ab+/en_us.lua, then overrides from rep/en_us.lua and rep+/en_us.lua when the game is
  Repentance+ without REPENTOGON; this script merges them the same way.
- Heart containers, soul and black hearts come from the game's own items.xml attributes
  (maxhearts/soulhearts/blackhearts, in half hearts), which the game applies on pickup.
- Weapon-type flags come from WEAPONS below (vanilla ids checked against EID's item names).
- The character flag comes from EID's features/eid_conditionals.lua (items EID shows a
  character-specific variant for) plus Birthright.

The EID files are read with a small Lua table reader below; nothing from the checkout is executed.
Rerun after a game update (with a fresh items.xml from afterbirthp.a, extracted in %TEMP%, never in
the game folder) or an EID update.
"""
import re
import sys
import xml.etree.ElementTree as ET

VERSION = '1.9.7.17.J460'

# ---------------------------------------------------------------- minimal Lua table reader

TOKEN = re.compile(r'''
    (?P<ws>\s+)
  | (?P<lcomment>--\[(?P<leq>=*)\[.*?\](?P=leq)\])
  | (?P<comment>--[^\n]*)
  | (?P<lstr>\[(?P<seq>=*)\[.*?\](?P=seq)\])
  | (?P<str>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
  | (?P<num>0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|[-+*/%^#&~|<>=(){}\[\];:,.])
''', re.S | re.X)
ESC = {'n': '\n', 't': '\t', 'r': '\r', 'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v'}


def unquote(s):
    if s.startswith('['):
        body = s[s.index('[', 1) + 1:s.rindex(']', 0, len(s) - 1)]
        return body[1:] if body.startswith('\n') else body
    out, body, i = [], s[1:-1], 0
    while i < len(body):
        c = body[i]
        if c == '\\':
            n = body[i + 1]
            m = re.match(r'\d{1,3}', body[i + 1:])
            if m:
                out.append(chr(int(m.group(0))))
                i += 1 + len(m.group(0))
                continue
            out.append(ESC.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def tokenize(text):
    pos, toks = 0, []
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise SyntaxError('bad character at offset %d: %r' % (pos, text[pos:pos + 20]))
        pos = m.end()
        kind = m.lastgroup
        if kind in ('ws', 'comment', 'lcomment'):
            continue
        if kind in ('str', 'lstr'):
            toks.append(('str', unquote(m.group(0))))
        elif kind == 'num':
            v = m.group(0)
            toks.append(('num', int(v, 16) if v[:2].lower() == '0x' else float(v)))
        else:
            toks.append((kind, m.group(0)))
    return toks


class TableReader:
    def __init__(self, toks, i):
        self.t, self.i = toks, i

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else ('eof', None)

    def take(self, val):
        tok = self.t[self.i]
        if tok[1] != val:
            raise SyntaxError('expected %r, got %r at token %d' % (val, tok, self.i))
        self.i += 1

    def value(self):
        kind, v = self.peek()
        if kind in ('str', 'num'):
            self.i += 1
            while self.peek()[1] == '..':      # "a" .. "b"
                self.i += 1
                v = str(v) + str(self.value())
            return v
        if v == '{':
            return self.table()
        if v == '-' and self.peek(1)[0] == 'num':
            self.i += 2
            return -self.t[self.i - 1][1]
        if kind == 'name':                     # identifier or call: kept as an opaque expression
            self.i += 1
            while True:
                v2 = self.peek()[1]
                if v2 in ('.', ':') and self.peek(1)[0] == 'name':
                    self.i += 2
                elif v2 == '(':
                    depth = 0
                    while True:
                        v3 = self.t[self.i][1]
                        self.i += 1
                        depth += (v3 == '(') - (v3 == ')')
                        if depth == 0:
                            break
                elif v2 == '[':
                    self.i += 1
                    self.value()
                    self.take(']')
                elif v2 == '..':
                    self.i += 1
                    self.value()
                else:
                    return ('expr', v)
        raise SyntaxError('unexpected %r at token %d' % ((kind, v), self.i))

    def table(self):
        self.take('{')
        arr, d = [], {}
        while self.peek()[1] != '}':
            kind, v = self.peek()
            if v == '[':
                self.i += 1
                key = self.value()
                self.take(']')
                self.take('=')
                d[key] = self.value()
            elif kind == 'name' and self.peek(1)[1] == '=':
                self.i += 2
                d[v] = self.value()
            else:
                arr.append(self.value())
            if self.peek()[1] in (',', ';'):
                self.i += 1
        self.take('}')
        if d:
            for n, a in enumerate(arr, 1):
                d.setdefault(n, a)
            return d
        return arr


def assigned_table(path, lvalue):
    """The table constructor assigned to `lvalue` (exact token text, e.g. 'repCollectibles')."""
    toks = tokenize(open(path, encoding='utf-8').read())
    want = tokenize(lvalue)
    n = len(want)
    for i in range(n, len(toks) - 1):
        if toks[i][1] == '=' and toks[i + 1][1] == '{' and toks[i - n:i] == want:
            return TableReader(toks, i + 1).table()
    raise KeyError('%s not assigned in %s' % (lvalue, path))


# ---------------------------------------------------------------- inputs

def load_eid(root):
    """{id: (name, description)} as EID shows it on Repentance+ without REPENTOGON."""
    d = root + '/descriptions/'
    out = {}
    for e in assigned_table(d + 'ab+/en_us.lua', 'EID.descriptions[languageCode].collectibles'):
        out[int(e[0])] = (e[1], e[2])
    for path, lv in ((d + 'rep/en_us.lua', 'repCollectibles'), (d + 'rep+/en_us.lua', 'collectibles')):
        for k, e in assigned_table(path, lv).items():
            if e == '':
                out.pop(int(k), None)
            else:
                out[int(k)] = (e[1], e[2])
    return out


def load_character_conditionals(root):
    """Collectible ids EID gives a character-specific variant (AddPlayerConditional & co)."""
    ids = set()
    text = open(root + '/features/eid_conditionals.lua', encoding='utf-8').read()
    for line in text.splitlines():
        code = line.split('--', 1)[0]
        m = re.search(r'EID:Add(?:Closest)?PlayerConditional\(\s*(\{[^}]*\}|\d+|"[^"]*")\s*,', code)
        if not m:
            continue
        for tok in re.findall(r'"5\.100\.(\d+)"|(?<![\d."])(\d+)(?![\d."])', m.group(1)):
            ids.add(int(tok[0] or tok[1]))
    return ids


def load_items(path):
    items = {}
    for e in ET.parse(path).getroot():
        if e.tag not in ('passive', 'active', 'familiar'):
            continue
        a = e.attrib
        items[int(a['id'])] = {
            'type': e.tag, 'hidden': a.get('hidden') == 'true', 'cache': set(a.get('cache', '').split()),
            'maxhearts': int(a.get('maxhearts', 0)), 'soulhearts': int(a.get('soulhearts', 0)),
            'blackhearts': int(a.get('blackhearts', 0)),
        }
    return items


# ---------------------------------------------------------------- curated flags

# Items that replace or reshape the main attack. Names are checked against EID's names.
WEAPONS = {
    52: ('Dr. Fetus', ['bombs']),
    68: ('Technology', ['laser']),
    69: ('Chocolate Milk', ['charged']),
    114: ("Mom's Knife", ['knife', 'charged']),
    118: ('Brimstone', ['brimstone', 'charged']),
    149: ('Ipecac', ['ipecac']),
    152: ('Technology 2', ['laser']),
    168: ('Epic Fetus', ['rockets']),
    229: ("Monstro's Lung", ['lung', 'charged']),
    316: ('Cursed Eye', ['charged']),
    329: ('The Ludovico Technique', ['ludovico']),
    395: ('Tech X', ['techx', 'charged']),
    531: ('Haemolacria', ['haemolacria', 'tearDelayFormula']),  # Rep: tear delay x2 + 11; EID's x0.33 approximates it
    533: ('Trisagion', ['trisagion']),
    579: ('Spirit Sword', ['sword', 'charged']),
    678: ('C Section', ['fetus', 'charged']),
}
EXTRA_CHARACTER = {619: 'Birthright'}
# Corrections where EID's text predates a Repentance+ change (checked on bindingofisaacrebirth.wiki.gg).
# {id: (EID name, {field: new value or None to drop})}
OVERRIDES = {
    120: ('Odd Mushroom (Thin)', {'tears': None, 'fireRate': 1.7}),  # Rep+: +1.7 flat fire rate, not +1.7 tears
}

# ---------------------------------------------------------------- description parsing

STAT_RX = re.compile(r'^([-+x])\s?(\d*\.?\d+)\s+(damage|tears|fire rate|range|shot speed|speed|luck)(\s+multiplier)?\b(.*)$', re.I)
STAT_KEY = {'damage': 'dmg', 'tears': 'tears', 'fire rate': 'fireRate', 'range': 'range',
            'shot speed': 'shotSpeed', 'speed': 'speed', 'luck': 'luck'}
MULT_KEY = {'damage': 'dmgMult', 'tears': 'tearsMult', 'fire rate': 'tearsMult', 'range': 'rangeMult',
            'shot speed': 'shotSpeedMult', 'speed': 'speedMult', 'luck': 'luckMult'}
STAT_ICONS = r'\{\{(?:Damage|Tears|Range|Shotspeed|Speed|Luck)\}\}'
HEART_RX = [  # (regex on the line, field, scale) -- EID counts full hearts
    (re.compile(r'^\{\{Heart\}\}\s*\+(\d+) Health$'), 'hearts'),
    (re.compile(r'^\{\{EmptyHeart\}\}\s*\+(\d+) Empty heart containers?$'), 'hearts'),
    (re.compile(r'^\{\{SoulHeart\}\}\s*\+(\d+) Soul Hearts?$'), 'soul'),
    (re.compile(r'^\{\{BlackHeart\}\}\s*\+(\d+) Black Hearts?$'), 'black'),
    (re.compile(r'^\{\{(?:Empty)?BoneHeart\}\}\s*\+(\d+) Bone Hearts?$'), 'bone'),
    (re.compile(r'^\{\{EternalHeart\}\}\s*\+(\d+) Eternal Hearts?$'), 'eternal'),
    (re.compile(r'^\{\{BrokenHeart\}\}\s*\+(\d+) Broken Hearts?$'), 'broken'),
    (re.compile(r'^\{\{RottenHeart\}\}\s*\+(\d+) Rotten Hearts?$'), 'rotten'),
]
TEAR_FLAGS = [  # whole-line tear flags; familiar items only when the line names Isaac
    (re.compile(r'^(?:Isaac (?:gains |has )?)?[Ff]light\b(?! and)'), ['flight']),
    (re.compile(r'^Flight and\b'), ['flight']),
    (re.compile(r'^(?:Isaac (?:shoots |has )?)?[Ss]pectral tears\b'), ['spectral']),
    (re.compile(r'^(?:Isaac (?:shoots |has )?)?[Pp]iercing tears\b'), ['piercing']),
    (re.compile(r'^(?:Isaac (?:shoots |has )?)?[Pp]iercing \+ spectral tears\b'), ['piercing', 'spectral']),
    (re.compile(r'^(?:Isaac (?:shoots |has )?)?[Hh]oming tears\b'), ['homing']),
]
# A line (or the header above it) with one of these describes a situational or temporary effect.
CONDITIONAL_RX = re.compile(
    r'\{\{Timer\}\}|for the room|current room|\bwhen\b|\bwhile\b(?! held)|\beach\b|\bevery\b|\bper\b|chance|%|'
    r'temporar|\bon hit\b|\bafter\b|\bif\b|builds? up|gradually|slowly|taking damage|clearing|\bkill|'
    r'standing|aura|first hit|additional hit|caps at|left eye|right eye|consecutive|up to|upon|until|'
    r'\blasts\b|seconds|depending|\buse\b|\bused\b|grants:|receive', re.I)
RANDOM_RX = re.compile(r"random stats?\b|Random stat (?:up|down)|stats? by between|Rerolls all of Isaac's items and stats", re.I)
# Other stat mentions without a plain pickup number (stat icon mid-line, "balances stats", ...).
OTHER_STAT_RX = re.compile(STAT_ICONS + r'.*?[-+x]\d|\bstats?\b.*\b(?:ups?|boost|increase|decrease|down)\b|'
                           r'\b(?:boosts?|balances?|increases?)\b.*\bstats?\b', re.I)
# The whole item is temporary although its lines read like plain stat ups (Red Stew).
WEARS_OFF_RX = re.compile(r'wears off', re.I)


def strip_markup(s):
    s = re.sub(r'\{\{Color\w*\}\}|\{\{CR\}\}', '', s)
    return s.replace('↑', '').replace('↓', '').strip()


def parse_item(iid, name, desc, kind):
    """Returns (stats {field: number}, flags set, conditional bool)."""
    stats, flags, conditional = {}, set(), False
    scope = None  # None: default; 'held': unconditional; 'cond': situational
    for raw in desc.split('#'):
        line = strip_markup(raw)
        if not line:
            continue
        # "Header: content" on one line (Dark Arts) or a header line ending in ':'
        head, content = line, None
        if ':' in line and not line.endswith(':'):
            h, rest = line.split(':', 1)
            if re.match(r'\s*(?:\{\{\w+\}\}\s*)?[-+x]\d', rest) or re.match(r'\s*' + STAT_ICONS, rest):
                head, content = h + ':', rest.strip()
        if head.endswith(':'):
            # every EID header ("Receive for the room:", "Spending 3 coins grants either:", ...) introduces
            # situational effects, except a bare "While held:"
            scope = 'held' if re.fullmatch(r'(?:\{\{\w+\}\}\s*)?while held:', head.strip(), re.I) else 'cond'
            if content is None:
                continue
            line = content
        on_use = kind == 'active' and scope != 'held' and not re.search(r'while held|on pickup', line, re.I)
        situational = scope == 'cond' or on_use or bool(CONDITIONAL_RX.search(line))

        if RANDOM_RX.search(line):
            flags.add('random')
            conditional = True
            continue
        body = re.sub(r'^' + STAT_ICONS + r'\s*', '', line)
        m = STAT_RX.match(body)
        if m and re.match(r'^' + STAT_ICONS, line):
            sign, num, stat, mult, tail = m.groups()
            stat = stat.lower()
            tail = re.sub(r'\([^)]*\)', '', tail).strip()
            if situational or tail:
                if re.search(r'left eye|right eye', tail, re.I):
                    flags.add('oneEye')
                conditional = True
                continue
            v = float(num)
            if sign == 'x' or mult:
                key = MULT_KEY[stat]
                stats[key] = stats.get(key, 1.0) * v
            else:
                key = STAT_KEY[stat]
                stats[key] = stats.get(key, 0.0) + (v if sign == '+' else -v)
            continue
        if re.match(r'^' + STAT_ICONS, line):
            m2 = re.search(r'Sets your Speed to at least (\d*\.?\d+)', line)
            if m2 and not situational:
                stats['speedMin'] = float(m2.group(1))
            elif re.search(r'\b(up|down|increase|decrease|grants|gain|bonus|damage|tears|fire rate|range|speed|luck)\b', line, re.I) \
                    and not re.search(r"chance|Isaac's (?:tear )?damage|his damage|per second", line, re.I):
                conditional = True  # a stat change without a plain number (scales, builds up, ...)
            continue
        hit = False
        for rx, field in HEART_RX:
            mh = rx.match(line)
            if mh:
                hit = True
                if situational:
                    conditional = True
                else:
                    stats['eid_' + field] = stats.get('eid_' + field, 0) + int(mh.group(1))
                break
        if hit:
            continue
        if OTHER_STAT_RX.search(line):
            conditional = True
            continue
        if kind == 'familiar' and 'Isaac' not in line:
            continue
        flagline = re.sub(r'^(?:\{\{\w+\}\}\s*)+', '', line)
        for rx, fl in TEAR_FLAGS:
            if rx.match(flagline):
                if situational and not re.search(r'while held', line, re.I):
                    conditional = True
                else:
                    flags.update(fl)
                break
    if WEARS_OFF_RX.search(desc):
        stats = {k: v for k, v in stats.items() if k.startswith('eid_')}
        conditional = True
    return stats, flags, conditional


# ---------------------------------------------------------------- output

def fmt(v):
    s = ('%.4f' % v).rstrip('0').rstrip('.')
    return s if s not in ('-0', '') else '0'


def main(eid_root, gamedata, out):
    eid = load_eid(eid_root)
    items = load_items(gamedata + '/items.xml')
    chars = load_character_conditionals(eid_root) | set(EXTRA_CHARACTER)
    for iid, (wname, _) in WEAPONS.items():
        assert eid[iid][0] == wname, (iid, eid[iid][0], wname)

    rows, report = {}, {'no_eid': [], 'heart_mismatch': [], 'cache_missing': [], 'flight_cache': []}
    for iid in sorted(items):
        it = items[iid]
        if iid not in eid:
            report['no_eid'].append(iid)
            continue
        stats, flags, cond = parse_item(iid, eid[iid][0], eid[iid][1], it['type'])
        if iid in WEAPONS:
            flags.update(WEAPONS[iid][1])
        if iid in OVERRIDES:
            assert eid[iid][0] == OVERRIDES[iid][0], (iid, eid[iid][0])
            for k, v in OVERRIDES[iid][1].items():
                if v is None:
                    stats.pop(k, None)
                else:
                    stats[k] = v
        if iid in chars:
            flags.add('character')
        # health: items.xml is authoritative for containers / soul / black (half hearts -> hearts)
        game = {'hearts': it['maxhearts'] / 2, 'soul': it['soulhearts'] / 2, 'black': it['blackhearts'] / 2}
        for f in ('hearts', 'soul', 'black'):
            e = stats.pop('eid_' + f, 0)
            if e != game[f]:
                report['heart_mismatch'].append((iid, f, 'eid=%s' % e, 'items.xml=%s' % game[f]))
            if game[f] or e:
                stats[f] = game[f] or e  # items.xml first; EID only for code-driven hearts (Abaddon)
        for f in ('bone', 'eternal', 'broken', 'rotten'):
            if 'eid_' + f in stats:
                stats[f] = stats.pop('eid_' + f)
        # cross-check against the item's cache flags (which stats the game re-evaluates on pickup)
        need = {'dmg': 'damage', 'dmgMult': 'damage', 'tears': 'firedelay', 'tearsMult': 'firedelay',
                'fireRate': 'firedelay', 'range': 'range', 'rangeMult': 'range', 'shotSpeed': 'shotspeed',
                'shotSpeedMult': 'shotspeed', 'speed': 'speed', 'speedMin': 'speed', 'luck': 'luck'}
        for k, c in need.items():
            if k in stats and c not in it['cache'] and 'all' not in it['cache']:
                report['cache_missing'].append((iid, k, c))
        if 'flight' in flags and not it['cache'] & {'flying', 'all'}:
            report['flight_cache'].append((iid, 'flag without cache'))
        if 'flying' in it['cache'] and 'flight' not in flags and not cond:
            report['flight_cache'].append((iid, 'cache without flag'))
        if stats or flags or cond:
            rows[iid] = (stats, flags, cond)

    order = ['dmg', 'dmgMult', 'tears', 'tearsMult', 'fireRate', 'range', 'rangeMult', 'shotSpeed', 'shotSpeedMult',
             'speed', 'speedMin', 'luck', 'hearts', 'soul', 'black', 'bone', 'eternal', 'rotten', 'broken']
    o = ['-- Generated by tools/gen_item_stats.py. Do not edit by hand. Repentance+ v%s, no REPENTOGON.' % VERSION,
         '-- Stats/flags derived from External Item Descriptions (github.com/wofsauge/External-Item-Descriptions,',
         '-- ab+ -> rep -> rep+ English descriptions); heart containers/soul/black from the game\'s items.xml.',
         '-- [collectibleId] = plain changes on pickup, zero fields omitted. Absent id = no stat change listed.',
         '--   dmg      flat damage           dmgMult    damage multiplier',
         '--   tears    "tears up" stat T, summed with the character\'s: tear delay = 16 - 6*sqrt(1.3*T + 1) for T >= 0',
         '--            (not below 5, reached at T = 1.816), 16 - 6*sqrt(1.3*T + 1) - 6*T for -0.77 < T < 0, 16 - 6*T below',
         '--   fireRate flat fire-rate bonus S, tearsMult fire-rate multiplier P: fire rate = (30/(delay+1) + S) * P',
         '--   range    Rep range units (+1.5 = one "range up")   rangeMult, shotSpeed, shotSpeedMult, speed, luck',
         '--   speedMin  sets speed to at least this value (while held)',
         '--   hearts/soul/black/bone/eternal/rotten/broken: full hearts (1 = one container / one full soul heart)',
         '--   flags: flight spectral piercing homing | weapon: brimstone laser knife bombs rockets ipecac ludovico techx',
         '--          lung haemolacria trisagion sword fetus, charged (attack must be charged) |',
         '--          oneEye (stat for one eye only) random (random stats) character (differs by character)',
         '--          tearDelayFormula (tearsMult approximates a tear-delay formula)',
         '--   conditional=true: the item also (or only) has situational/temporary/on-use stat changes not given as numbers',
         'return {']
    for iid in sorted(rows):
        stats, flags, cond = rows[iid]
        parts = ['%s=%s' % (k, fmt(stats[k])) for k in order if k in stats and stats[k] != (1.0 if k.endswith('Mult') else 0)]
        if flags:
            parts.append('flags={%s}' % ','.join('"%s"' % f for f in sorted(flags)))
        if cond:
            parts.append('conditional=true')
        o.append('  [%d] = { %s }, -- %s' % (iid, ', '.join(parts), eid[iid][0].replace('\n', ' ')))
    o.append('}')
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(o) + '\n')

    visible = [i for i in items if not items[i]['hidden']]
    numeric = [i for i in rows if any(k in rows[i][0] for k in order)]
    print('collectibles in items.xml: %d (%d not hidden); with EID text: %d' % (
        len(items), len(visible), len(items) - len(report['no_eid'])))
    print('entries: %d; with numbers: %d; with flags: %d; conditional: %d; conditional only (no numbers): %d' % (
        len(rows), len(numeric), sum(1 for i in rows if rows[i][1]), sum(1 for i in rows if rows[i][2]),
        sum(1 for i in rows if rows[i][2] and i not in numeric)))
    for k, v in report.items():
        print('%s (%d): %s' % (k, len(v), v))
    print('->', out)
    return rows, eid, items


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3])
