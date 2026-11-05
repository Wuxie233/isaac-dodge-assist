#!/usr/bin/env python3
"""Render the mod's HUD and F5 panel offline with the game's own font atlases.

    python3 native/tests/ui_preview/ui_preview.py <font dir> <out dir>

<font dir> holds font/cjk/lanapixel.fnt+png and font/luaminioutlined.fnt+png
as extracted from the game (afterbirthp.a, see native/research/text-and-fonts.md).
Writes <lang>_<scene>.png (480x270 game pixels, upscaled x3) for zh/en x
hud/panel/page (F5 second page)/room (pedestal tooltip and pill labels). The harness runs the real hud.lua/map_view.lua; this only draws
what they asked for. A layout check, not a screenshot of the game.
"""
import os, struct, subprocess, sys, tempfile
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
FONTS = {'zh': 'font/cjk/lanapixel.fnt', 'en': 'font/luaminioutlined.fnt'}


def parse_fnt(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'BMF\x03', path
    pos, out = 4, {'chars': {}}
    while pos < len(b):
        t, n = b[pos], struct.unpack_from('<I', b, pos + 1)[0]
        d = b[pos + 5:pos + 5 + n]; pos += 5 + n
        if t == 2:
            out['lineHeight'], out['base'] = struct.unpack_from('<HH', d)
        elif t == 3:
            out['pages'] = [p.decode('latin1') for p in d.split(b'\0') if p]
        elif t == 4:
            for i in range(0, len(d), 20):
                cid, x, y, w, h, xo, yo, xa, pg, ch = struct.unpack_from('<IHHHHhhhBB', d, i)
                out['chars'][cid] = (x, y, w, h, xo, yo, xa, pg)
    return out


def load_font(base, rel):
    path = os.path.join(base, rel)
    f = parse_fnt(path)
    # The archive stores files lowercase; the .fnt names its pages as drawn.
    f['atlas'] = [Image.open(os.path.join(os.path.dirname(path), p.lower())).convert('RGBA') for p in f['pages']]
    return f


def background():
    img = Image.new('RGBA', (480, 270), (58, 46, 40, 255))
    px = img.load()
    for y in range(270):
        for x in range(480):
            if (x // 26 + y // 26) % 2 == 0:
                px[x, y] = (64, 51, 44, 255)
    return img


def blend(img, x0, y0, w, h, rgba):
    r, g, b, a = rgba
    over = Image.new('RGBA', (max(1, round(w)), max(1, round(h))), (int(r*255), int(g*255), int(b*255), int(a*255)))
    img.alpha_composite(over, (int(round(x0)), int(round(y0))))


def draw_text(img, font, x, y, rgba, text):
    pen = round(x)
    for ch in text:
        c = font['chars'].get(ord(ch)) or font['chars'].get(ord('?'))
        if not c:
            continue
        ax, ay, w, h, xo, yo, xa, pg = c
        if w and h:
            glyph = font['atlas'][pg].crop((ax, ay, ax + w, ay + h))
            r, g, b, a = rgba
            data = [(int(pr*r), int(pg_*g), int(pb*b), int(pa*a)) for pr, pg_, pb, pa in glyph.getdata()]
            glyph.putdata(data)
            px, py = pen + xo, round(y) + yo
            if 0 <= px < 480 and 0 <= py < 270:
                img.alpha_composite(glyph, (px, py))
        pen += xa


def main(font_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for lang, rel in FONTS.items():
        font = load_font(font_dir, rel)
        with tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False) as adv:
            adv.write('return {' + ','.join(f'[{k}]={v[6]}' for k, v in font['chars'].items()) + '}')
        for scene in ('hud', 'panel', 'page', 'room'):
            calls = subprocess.run(['lua5.3', 'native/tests/ui_preview/harness.lua', lang, adv.name, scene],
                                   cwd=ROOT, capture_output=True, text=True, check=True).stdout.splitlines()
            img = background()
            for line in calls:
                part = line.split('\t')
                if part[0] == 'R':
                    x, y, w, h = map(float, part[1:5])
                    blend(img, x, y, w, h, tuple(map(float, part[5].split(','))))
                elif part[0] == 'T':
                    draw_text(img, font, float(part[2]), float(part[3]), tuple(map(float, part[4].split(','))), part[5])
            img = img.resize((480*3, 270*3), Image.NEAREST)
            target = os.path.join(out_dir, f'{lang}_{scene}.png')
            img.save(target)
            print(target, len(calls), 'draw calls')
        os.unlink(adv.name)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
