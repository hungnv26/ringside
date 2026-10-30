"""Draws the Dojo's painted art (tools/build_dojo_stage.gd), seeded so rebuilds match:

- scroll.png: the kamiza's hanging scroll. A brocade mount (a small repeating pattern in
  dark olive and gold), aged paper with fibres and foxing, 道 ("the way") in brush ink
  that bleeds a little into the paper, and a red seal (武) stamped below it.
- taiko_head.png: a taiko drum head. Tanned hide, darker toward the rim where hands
  don't reach, worn paler in the middle where it's struck, and the mitsudomoe (three
  comma-shaped swirls) painted in black.

The kanji are drawn with the Yuji Syuku brush font (SIL Open Font Licence; the font is used
to draw these images and is not shipped):

    python3 tools/make_dojo_art.py <YujiSyuku-Regular.ttf> assets/stages/dojo/art
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

rng = random.Random(1964)


def noise(size, scale, seed):
    r = random.Random(seed)
    small = Image.new("L", (max(1, size[0] // scale), max(1, size[1] // scale)))
    small.putdata([r.randint(0, 255) for _ in range(small.size[0] * small.size[1])])
    return small.resize(size, Image.BICUBIC)


def scroll(font_path, out):
    W, H = 512, 1152
    img = Image.new("RGB", (W, H), (60, 58, 40))
    d = ImageDraw.Draw(img)
    # Brocade: a lattice of small diamonds in old gold on dark olive.
    for y in range(0, H, 18):
        for x in range(0, W, 18):
            ox = 9 if (y // 18) % 2 else 0
            cx, cy = x + ox, y + 9
            d.polygon([(cx, cy - 5), (cx + 5, cy), (cx, cy + 5), (cx - 5, cy)], fill=(112, 96, 52))
    img = Image.blend(img, Image.merge("RGB", [noise((W, H), 6, 1)] * 3), 0.08)
    # Paper panel with a thin gold border strip.
    px0, py0, px1, py1 = 70, 150, W - 70, H - 170
    d = ImageDraw.Draw(img)
    d.rectangle([px0 - 8, py0 - 8, px1 + 8, py1 + 8], fill=(150, 120, 60))
    paper = Image.new("RGB", (px1 - px0, py1 - py0), (232, 222, 196))
    fibres = ImageDraw.Draw(paper)
    for _ in range(900):
        x, y = rng.randrange(paper.size[0]), rng.randrange(paper.size[1])
        a = rng.random() * math.tau
        L = rng.uniform(4, 18)
        tone = rng.randint(200, 226)
        fibres.line([x, y, x + L * math.cos(a), y + L * math.sin(a)], fill=(tone, tone - 8, tone - 26), width=1)
    for _ in range(14):  # foxing: small brown age spots
        x, y = rng.randrange(paper.size[0]), rng.randrange(paper.size[1])
        r = rng.uniform(3, 12)
        fibres.ellipse([x - r, y - r, x + r, y + r], fill=(206, 186, 150))
    paper = paper.filter(ImageFilter.GaussianBlur(0.8))
    paper = Image.blend(paper, Image.merge("RGB", [noise(paper.size, 40, 2)] * 3), 0.06)
    # The kanji: ink, bleeding a little, with dry-brush gaps.
    font = ImageFont.truetype(font_path, 330)
    ink = Image.new("L", paper.size, 0)
    di = ImageDraw.Draw(ink)
    bbox = di.textbbox((0, 0), "道", font=font)
    tx = (paper.size[0] - (bbox[2] - bbox[0])) // 2 - bbox[0]
    ty = int(paper.size[1] * 0.36) - (bbox[3] - bbox[1]) // 2 - bbox[1]
    di.text((tx, ty), "道", fill=255, font=font)
    bleed = ink.filter(ImageFilter.GaussianBlur(2.2)).point(lambda v: min(255, int(v * 0.55)))
    dry = noise((paper.size[0], paper.size[1]), 9, 3).point(lambda v: 0 if v < 38 else 255).filter(ImageFilter.GaussianBlur(1.0))
    ink = ImageChops.multiply(ink, dry)
    ink = ImageChops.lighter(ink, bleed)
    paper.paste((24, 20, 18), (0, 0), ink)
    # The seal: a red square with the character cut out in white, slightly uneven.
    seal = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
    ds = ImageDraw.Draw(seal)
    ds.rounded_rectangle([4, 4, 92, 92], 6, fill=(178, 34, 26, 235))
    sf = ImageFont.truetype(font_path, 74)
    sb = ds.textbbox((0, 0), "武", font=sf)
    ds.text(((96 - (sb[2] - sb[0])) // 2 - sb[0], (96 - (sb[3] - sb[1])) // 2 - sb[1]), "武", fill=(236, 214, 196, 255), font=sf)
    seal = seal.rotate(-3, resample=Image.BICUBIC)
    paper.paste(seal, (paper.size[0] - 150, int(paper.size[1] * 0.7)), seal)
    img.paste(paper, (px0, py0))
    img.save(os.path.join(out, "scroll.png"))


def taiko_head(out):
    S = 512
    c = S / 2
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hide = Image.new("RGB", (S, S))
    px = hide.load()
    grain = noise((S, S), 4, 4).load()
    for y in range(S):
        for x in range(S):
            r = math.hypot(x - c, y - c) / c
            worn = math.exp(-((r / 0.42) ** 2)) * 0.12
            edge = max(0.0, r - 0.72) * 0.9
            g = (grain[x, y] - 128) / 128 * 0.05
            k = 1.0 - edge + worn + g
            px[x, y] = (int(214 * k), int(176 * k), int(122 * k))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).ellipse([2, 2, S - 3, S - 3], fill=255)
    img.paste(hide, (0, 0), mask)
    # Mitsudomoe: three commas swirling round the centre.
    emblem = Image.new("L", (S, S), 0)
    de = ImageDraw.Draw(emblem)
    R = S * 0.3
    for k in range(3):
        a0 = k * math.tau / 3
        head = (c + 0.42 * R * math.cos(a0), c + 0.42 * R * math.sin(a0))
        hr = 0.36 * R
        de.ellipse([head[0] - hr, head[1] - hr, head[0] + hr, head[1] + hr], fill=255)
        tail = []
        for i in range(40):
            t = i / 39
            a = a0 + t * 2.3
            rad = 0.42 * R + t * 0.56 * R
            w = hr * (1 - t) ** 1.2
            tail.append((c + rad * math.cos(a), c + rad * math.sin(a), w))
        for x, y, w in tail:
            de.ellipse([x - w, y - w, x + w, y + w], fill=255)
    emblem = emblem.filter(ImageFilter.GaussianBlur(1.2))
    img.paste((18, 14, 12), (0, 0), ImageChops.multiply(emblem, mask))
    img.save(os.path.join(out, "taiko_head.png"))


def main():
    font_path, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    scroll(font_path, out)
    taiko_head(out)
    print("saved", out)


if __name__ == "__main__":
    main()
