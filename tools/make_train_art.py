"""Draws the Express's tree atlas (tools/build_train_stage.gd), seeded so rebuilds match:
trees.png, 2 x 2 cells of 512 px on a transparent background, each a tree seen from the
side with its base at the bottom centre of the cell:

- a spruce: a straight trunk under tiers of drooping branches thick with needle strokes,
  darker inside, a spire at the top;
- a broadleaf (oak-like): a forked trunk and limbs holding clumps of leaves, lit from the
  upper left, shaded underneath;
- a bush: a low mound of leaf clumps;
- a poplar: a tall, narrow crown of leaf clumps on a slim trunk.

Leaves and needles are many small marks in several greens, so the cards read as foliage
rather than flat shapes. Cross-carded in the game (three cards per tree).

    python3 tools/make_train_art.py assets/stages/train/art
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

CELL = 512
S = 2
rng = random.Random(1997)


def jitter(c, amount):
    return tuple(max(0, min(255, int(v + rng.uniform(-amount, amount)))) for v in c)


def leaf_clump(d, cx, cy, r, base, light_dir=(-0.6, -0.8), count=None):
    """A clump: many small leaf ellipses, lighter toward the light, darker underneath."""
    count = count or int(r * r / (14 * S * S)) + 30
    for _ in range(count):
        a = rng.random() * math.tau
        rr = r * math.sqrt(rng.random())
        x, y = cx + rr * math.cos(a), cy + rr * math.sin(a) * 0.85
        lit = ((x - cx) * light_dir[0] + (y - cy) * light_dir[1]) / max(r, 1)
        k = 0.72 + 0.38 * max(-1.0, min(1.0, lit)) + rng.uniform(-0.08, 0.08)
        col = tuple(max(0, min(255, int(c * k))) for c in base)
        w = rng.uniform(3, 7) * S
        h = w * rng.uniform(0.5, 0.8)
        ang = rng.random() * math.tau
        pts = []
        for t in range(8):
            u = t / 8 * math.tau
            px, py = math.cos(u) * w, math.sin(u) * h
            pts.append((x + px * math.cos(ang) - py * math.sin(ang), y + px * math.sin(ang) + py * math.cos(ang)))
        d.polygon(pts, fill=col + (255,))


def trunk(d, x0, y0, x1, y1, w0, w1, col):
    steps = 20
    for i in range(steps):
        t0, t1 = i / steps, (i + 1) / steps
        xa, ya = x0 + (x1 - x0) * t0, y0 + (y1 - y0) * t0
        xb, yb = x0 + (x1 - x0) * t1, y0 + (y1 - y0) * t1
        d.line([(xa, ya), (xb, yb)], fill=jitter(col, 8) + (255,), width=max(1, int(w0 + (w1 - w0) * t0)))


def spruce():
    img = Image.new("RGBA", (CELL * S, CELL * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    W, H = CELL * S, CELL * S
    cx = W / 2
    trunk(d, cx, H, cx, H * 0.08, 18 * S, 4 * S, (70, 50, 36))
    tiers = 22
    for k in range(tiers):
        t = k / (tiers - 1)  # 0 bottom, 1 top
        y = H * (0.86 - 0.8 * t)
        for side in (-1, 1):
            reach = (W * 0.42 * (1 - t) ** 0.9 + W * 0.03) * rng.uniform(0.82, 1.1)  # ragged tiers
            # A drooping branch: a dark mass, then needles along it, denser near the tips.
            mass = [(cx, y - 8 * S)]
            for i in range(11):
                u = i / 10
                mass.append((cx + side * reach * u, y + reach * 0.22 * u * u - 10 * S * (1 - u)))
            for i in range(10, -1, -1):
                u = i / 10
                mass.append((cx + side * reach * u * 0.96, y + reach * 0.22 * u * u + 14 * S * (1 - 0.5 * u)))
            d.polygon(mass, fill=jitter((22, 46, 28), 6) + (255,))
            for i in range(240):
                u = rng.random() ** 0.8
                bx = cx + side * reach * u
                by = y + reach * 0.22 * u * u + rng.uniform(-9, 11) * S
                base = (34, 76, 42) if u < 0.6 else (46, 96, 52)
                col = jitter(base, 12)
                if by > y + reach * 0.22 * u * u + 6 * S:
                    col = tuple(int(c * 0.72) for c in col)  # the underside
                a = math.pi / 2 + rng.uniform(-1.0, 1.0)
                L = rng.uniform(6, 13) * S
                d.line([(bx, by), (bx + L * math.cos(a) * 0.7 * side, by + L * math.sin(a) * 0.45)], fill=col + (255,), width=int(2.4 * S))
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    return img


def broadleaf():
    img = Image.new("RGBA", (CELL * S, CELL * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    W, H = CELL * S, CELL * S
    cx = W / 2
    bark = (72, 58, 46)
    trunk(d, cx, H, cx + 6 * S, H * 0.55, 30 * S, 18 * S, bark)
    limbs = [(-0.22, 0.32), (0.2, 0.28), (-0.05, 0.18), (0.3, 0.42), (-0.32, 0.45)]
    for lx, ly in limbs:
        trunk(d, cx + 6 * S, H * 0.6, cx + W * lx, H * ly, 14 * S, 5 * S, bark)
    clumps = []
    for _ in range(40):
        a = rng.random() * math.tau
        r = math.sqrt(rng.random()) * 0.34 * W
        clumps.append((cx + math.cos(a) * r * 1.1, H * 0.36 + math.sin(a) * r * 0.7, rng.uniform(0.07, 0.12) * W))
    clumps.sort(key=lambda c: c[1])
    for x, y, r in clumps:
        leaf_clump(d, x, y, r, jitter((70, 112, 40), 14))
    return img.filter(ImageFilter.GaussianBlur(0.6))


def bush():
    img = Image.new("RGBA", (CELL * S, CELL * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    W, H = CELL * S, CELL * S
    cx = W / 2
    for _ in range(20):
        x = cx + rng.uniform(-0.3, 0.3) * W
        r = rng.uniform(0.09, 0.15) * W
        y = H * rng.uniform(0.72, 0.9)
        y = min(y, H - r * 0.85)
        leaf_clump(d, x, y, r, jitter((64, 100, 38), 14))
    return img.filter(ImageFilter.GaussianBlur(0.6))


def poplar():
    img = Image.new("RGBA", (CELL * S, CELL * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    W, H = CELL * S, CELL * S
    cx = W / 2
    trunk(d, cx, H, cx, H * 0.15, 16 * S, 5 * S, (96, 88, 74))
    for k in range(30):
        t = k / 29
        y = H * (0.82 - 0.74 * t)
        half = W * 0.16 * math.sin(math.pi * (0.15 + 0.85 * t)) + W * 0.02
        leaf_clump(d, cx + rng.uniform(-half, half) * 0.6, y, half * rng.uniform(0.6, 0.9), jitter((84, 120, 44), 12))
    return img.filter(ImageFilter.GaussianBlur(0.6))


def bleed(img):
    rgb = img.convert("RGB")
    a = img.getchannel("A")
    fill = rgb.filter(ImageFilter.GaussianBlur(14))
    mask = a.point(lambda v: 255 if v > 8 else 0)
    rgb = Image.composite(rgb, Image.composite(fill, Image.new("RGB", rgb.size, (50, 80, 40)), fill.convert("L").point(lambda v: 255 if v > 10 else 0)), mask)
    rgb.putalpha(a)
    return rgb


def main(out):
    os.makedirs(out, exist_ok=True)
    atlas = Image.new("RGBA", (CELL * 2, CELL * 2), (0, 0, 0, 0))
    for i, make in enumerate([spruce, broadleaf, bush, poplar]):
        cell = make().resize((CELL, CELL), Image.LANCZOS)
        atlas.paste(cell, ((i % 2) * CELL, (i // 2) * CELL))
    bleed(atlas).save(os.path.join(out, "trees.png"))
    print("saved", out)


if __name__ == "__main__":
    main(sys.argv[1])
