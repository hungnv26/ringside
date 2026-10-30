"""Draws the Beach's palm frond (tools/build_beach_stage.gd), seeded so rebuilds match:
frond.png, a coconut-palm frond seen from above on a transparent background, its base at
the bottom and its tip at the top: a midrib that thins toward the tip, and on each side a
row of long, narrow leaflets angled toward the tip, greener at the base and yellowing at
their tips, a few torn or missing.

    python3 tools/make_beach_art.py assets/stages/beach/art
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

rng = random.Random(77)


def frond(out):
    W, H = 512, 1024
    S = 2
    img = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = W * S / 2
    pairs = 46
    for k in range(pairs):
        t = (k + 0.5) / pairs  # 0 at the base, 1 at the tip
        y = H * S * (0.97 - 0.94 * t)
        for side in (-1, 1):
            if rng.random() < 0.06:
                continue  # a missing leaflet
            length = W * S * (0.46 * math.sin(math.pi * (0.12 + 0.8 * t)) + 0.04) * rng.uniform(0.85, 1.05)
            angle = math.radians(rng.uniform(52, 64))  # leaflets point toward the tip
            droop = rng.uniform(0.0, 0.12)
            width = S * rng.uniform(9, 14) * (1.1 - 0.5 * t)
            base_green = (rng.randint(54, 74), rng.randint(104, 128), rng.randint(36, 52))
            pts_l, pts_r = [], []
            steps = 14
            for i in range(steps + 1):
                u = i / steps
                bend = angle - droop * u
                x = cx + side * math.sin(bend) * length * u
                yy = y - math.cos(bend) * length * u + droop * 40 * S * u * u
                w = width * (1 - u) ** 0.6 + 1
                nx, ny = math.cos(bend), side * math.sin(bend)
                pts_l.append((x + nx * w * 0.5 * side, yy + ny * w * 0.5 * side))
                pts_r.append((x - nx * w * 0.5 * side, yy - ny * w * 0.5 * side))
            tip = rng.uniform(0.55, 0.9)
            colour = tuple(int(c * (1 - 0.15 * t)) for c in base_green)
            d.polygon(pts_l + pts_r[::-1], fill=colour + (255,))
            # Yellowing toward the leaflet's tip.
            cut = int(steps * tip)
            if cut < steps:
                yellow = (int(150 + 40 * rng.random()), int(140 + 30 * rng.random()), 60, 255)
                d.polygon(pts_l[cut:] + pts_r[cut:][::-1], fill=yellow)
            # A darker vein along the leaflet.
            d.line([((pts_l[i][0] + pts_r[i][0]) / 2, (pts_l[i][1] + pts_r[i][1]) / 2) for i in range(steps + 1)],
                   fill=(40, 74, 30, 255), width=max(1, int(S * 1.5)))
    # The midrib, thick at the base.
    for i in range(60):
        t = i / 59
        y0 = H * S * (0.99 - 0.97 * t)
        y1 = H * S * (0.99 - 0.97 * (t + 1 / 59))
        w = S * (16 * (1 - t) + 2)
        d.line([(cx, y0), (cx, y1)], fill=(150, 140, 70, 255), width=int(w))
    img = img.filter(ImageFilter.GaussianBlur(0.7)).resize((W, H), Image.LANCZOS)
    # Colour into the clear texels so mipmaps don't fringe dark.
    rgb = img.convert("RGB")
    a = img.getchannel("A")
    fill = rgb.filter(ImageFilter.GaussianBlur(10))
    rgb = Image.composite(rgb, Image.composite(fill, Image.new("RGB", rgb.size, (60, 100, 40)), fill.convert("L").point(lambda v: 255 if v > 10 else 0)), a.point(lambda v: 255 if v > 8 else 0))
    rgb.putalpha(a)
    rgb.save(os.path.join(out, "frond.png"))


if __name__ == "__main__":
    frond(sys.argv[1])
    print("saved", sys.argv[1])
