"""Draws the cherry-blossom cluster atlas (and petal.png, one white petal shape for the
falling petals, tinted by the particles) for the Temple's trees (tools/blender/build_cherry_tree.py):
2x2 cells of 512 px, each a loose cluster of five-petal sakura flowers (pale pink, a notch at
each petal tip, a deeper pink eye with stamens) with a few young leaves and buds, on a
transparent background. Seeded, so rebuilds match.

    python3 tools/blender/make_blossom_texture.py assets/stages/temple/cherry/textures/blossom.png
"""
import math
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

CELL = 512
SCALE = 2  # drawn at twice the size, then reduced (smooth edges)


def petal(draw, cx, cy, angle, length, width, colour):
    """One petal: an ellipse-ish blade from the centre, with a small notch at its tip."""
    pts = []
    for i in range(25):
        t = i / 24.0
        r = length * t
        w = width * math.sin(math.pi * min(t, 0.98)) * (1.0 - 0.15 * t)
        pts.append((r, w))
    outline = pts + [(r, -w) for r, w in reversed(pts)]
    notch = [(length * 0.9, 0.0)]
    poly = []
    for r, w in outline[:24] + notch + outline[26:]:
        x = cx + r * math.cos(angle) - w * math.sin(angle)
        y = cy + r * math.sin(angle) + w * math.cos(angle)
        poly.append((x, y))
    draw.polygon(poly, fill=colour)


def flower(draw, rng, cx, cy, size):
    base = rng.choice([(255, 214, 226), (252, 200, 216), (255, 228, 236), (247, 190, 208)])
    turn = rng.random() * math.tau
    for k in range(5):
        shade = tuple(max(0, min(255, c + rng.randint(-10, 6))) for c in base) + (255,)
        petal(draw, cx, cy, turn + k * math.tau / 5, size, size * 0.42, shade)
    eye = size * 0.3
    draw.ellipse([cx - eye, cy - eye, cx + eye, cy + eye], fill=(214, 92, 128, 255))
    for k in range(9):
        a = rng.random() * math.tau
        r = size * rng.uniform(0.25, 0.5)
        x, y = cx + r * math.cos(a), cy + r * math.sin(a)
        draw.line([cx, cy, x, y], fill=(190, 70, 105, 255), width=max(1, int(size * 0.04)))
        d = size * 0.05
        draw.ellipse([x - d, y - d, x + d, y + d], fill=(245, 205, 120, 255))


def leaf(draw, rng, cx, cy, size):
    angle = rng.random() * math.tau
    green = rng.choice([(96, 128, 52), (120, 140, 60), (140, 110, 60)])
    petal(draw, cx, cy, angle, size, size * 0.3, green + (255,))


def cell(rng):
    size = CELL * SCALE
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Twigs first, then leaves and buds, then the flowers on top.
    for _ in range(5):
        x, y = size / 2 + rng.uniform(-80, 80), size / 2 + rng.uniform(-80, 80)
        a = rng.random() * math.tau
        L = rng.uniform(0.25, 0.45) * size
        draw.line([x, y, x + L * math.cos(a), y + L * math.sin(a)], fill=(70, 46, 40, 255), width=10)
    for _ in range(rng.randint(3, 6)):
        r = rng.uniform(0.1, 0.38) * size
        a = rng.random() * math.tau
        leaf(draw, rng, size / 2 + r * math.cos(a), size / 2 + r * math.sin(a), rng.uniform(70, 120))
    flowers = []
    for _ in range(rng.randint(48, 58)):
        # Denser in the middle, thinning to the edges (the card's outline stays soft).
        r = (rng.random() ** 0.6) * 0.43 * size
        a = rng.random() * math.tau
        flowers.append((size / 2 + r * math.cos(a), size / 2 + r * math.sin(a), rng.uniform(52, 82)))
    flowers.sort(key=lambda f: f[1])
    for x, y, s in flowers:
        if rng.random() < 0.12:  # a bud
            draw.ellipse([x - s * 0.3, y - s * 0.4, x + s * 0.3, y + s * 0.4], fill=(232, 128, 160, 255))
        else:
            flower(draw, rng, x, y, s)
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    return img.resize((CELL, CELL), Image.LANCZOS)


def main():
    out = sys.argv[1]
    rng = random.Random(1868)
    atlas = Image.new("RGBA", (CELL * 2, CELL * 2), (0, 0, 0, 0))
    for i in range(4):
        atlas.paste(cell(rng), ((i % 2) * CELL, (i // 2) * CELL))
    # Colour bleeds into the transparent texels so mipmaps don't fringe dark.
    rgb = atlas.convert("RGB")
    alpha = atlas.getchannel("A")
    fill = rgb.filter(ImageFilter.GaussianBlur(12))
    mask = alpha.point(lambda a: 255 if a > 8 else 0)
    bled = Image.composite(rgb, Image.composite(fill, Image.new("RGB", rgb.size, (236, 180, 196)), fill.convert("L").point(lambda v: 255 if v > 20 else 0)), mask)
    bled.putalpha(alpha)
    bled.save(out)
    print("saved", out)
    # One loose petal for the falling-petal particles (petal.png beside the atlas).
    size = 128 * SCALE
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    petal(ImageDraw.Draw(img), size * 0.12, size * 0.5, 0.0, size * 0.82, size * 0.36, (255, 255, 255, 255))
    img = img.resize((128, 128), Image.LANCZOS)
    rgb = Image.new("RGB", img.size, (255, 255, 255))
    rgb.putalpha(img.getchannel("A"))
    path = out.replace("blossom.png", "petal.png")
    rgb.save(path)
    print("saved", path)


if __name__ == "__main__":
    main()
