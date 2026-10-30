"""Draws the fight effects' textures (scripts/fx/fight_fx.gd), seeded so rebuilds match:

- spark_streak.png: one hot spark streak, white core fading to the tail (tinted per hit).
- impact.png: a 4 x 4 flipbook (16 frames) of an impact burst: a hot core, sharp rays of
  uneven length that shoot out and thin, a ring of shock, all fading.
- smoke.png: a 4 x 4 flipbook of a puff of smoke or dust swelling, curling and thinning,
  shaded from above (light top, darker underside) so it reads as a volume when lit.
- footprint.png: a bare-foot / shoe print pressed into sand: a darker hollow (heel and
  forefoot) with a lighter rim of pushed-up sand (for the decal's albedo and alpha).

    python3 tools/make_fx_art.py assets/fx
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

rng = random.Random(4242)


def noise(size, scale, seed):
    r = random.Random(seed)
    small = Image.new("L", (max(2, size // scale), max(2, size // scale)))
    small.putdata([r.randint(0, 255) for _ in range(small.size[0] * small.size[1])])
    return small.resize((size, size), Image.BICUBIC)


def spark_streak(out):
    W, H = 64, 256
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    for i in range(H):
        t = i / H  # 0 = head (top), 1 = tail
        w = 10 * (1 - t) ** 0.7 + 1
        v = int(255 * (1 - t) ** 1.4)
        d.line([(W / 2 - w, i), (W / 2 + w, i)], fill=v)
    img = img.filter(ImageFilter.GaussianBlur(3))
    core = Image.new("L", (W, H), 0)
    ImageDraw.Draw(core).ellipse([W / 2 - 6, 6, W / 2 + 6, 40], fill=255)
    img = ImageChops.lighter(img, core.filter(ImageFilter.GaussianBlur(4)))
    rgba = Image.merge("RGBA", [Image.new("L", (W, H), 255)] * 3 + [img])
    rgba.save(os.path.join(out, "spark_streak.png"))


def impact(out):
    C = 256
    sheet = Image.new("RGBA", (C * 4, C * 4), (0, 0, 0, 0))
    rays = [(k * math.tau / 18 + rng.uniform(-0.12, 0.12), rng.uniform(0.4, 1.0), rng.uniform(0.5, 1.3)) for k in range(18)]
    for f in range(16):
        t = f / 15
        frame = Image.new("L", (C, C), 0)
        d = ImageDraw.Draw(frame)
        c = C / 2
        grow = 0.55 + 0.45 * (1 - (1 - t) ** 4)
        fade = (1 - t) ** 1.3
        for a, reach, w in rays:
            L = c * 0.95 * reach * grow
            inner = c * 0.08 + L * 0.35 * t
            wid = (C * 0.022) * w * (1 - t * 0.85)
            tip = (c + math.cos(a) * L, c + math.sin(a) * L)
            p0 = (c + math.cos(a) * inner + math.cos(a + 1.57) * wid, c + math.sin(a) * inner + math.sin(a + 1.57) * wid)
            p1 = (c + math.cos(a) * inner - math.cos(a + 1.57) * wid, c + math.sin(a) * inner - math.sin(a + 1.57) * wid)
            d.polygon([p0, tip, p1], fill=int(255 * fade))
        core_r = C * (0.11 * (1 - t) ** 2 + 0.02)
        d.ellipse([c - core_r, c - core_r, c + core_r, c + core_r], fill=int(255 * fade))
        ring_r = C * 0.45 * grow
        d.ellipse([c - ring_r, c - ring_r, c + ring_r, c + ring_r], outline=int(150 * fade), width=max(1, int(C * 0.02 * (1 - t))))
        frame = frame.filter(ImageFilter.GaussianBlur(1.2 + 2.5 * t))
        rgba = Image.merge("RGBA", [Image.new("L", (C, C), 255)] * 3 + [frame])
        sheet.paste(rgba, ((f % 4) * C, (f // 4) * C))
    sheet.save(os.path.join(out, "impact.png"))


def smoke(out):
    C = 256
    sheet = Image.new("RGBA", (C * 4, C * 4), (0, 0, 0, 0))
    blobs = []
    for _ in range(16):
        a = rng.random() * math.tau
        r = math.sqrt(rng.random()) * 0.2
        blobs.append((math.cos(a) * r, math.sin(a) * r * 0.8, rng.uniform(0.1, 0.2)))
    detail = noise(C, 22, 7).filter(ImageFilter.GaussianBlur(4))
    for f in range(16):
        t = f / 15
        dens = Image.new("L", (C, C), 0)
        d = ImageDraw.Draw(dens)
        c = C / 2
        swell = 0.5 + 0.7 * (1 - (1 - t) ** 2)
        for i, (bx, by, br) in enumerate(blobs):
            curl = 0.06 * t * math.sin(i * 1.7 + t * 3)
            x = c + (bx * swell + curl) * C
            y = c + (by * swell - 0.06 * t) * C
            r = br * C * swell
            d.ellipse([x - r, y - r, x + r, y + r], fill=170)
        dens = dens.filter(ImageFilter.GaussianBlur(9 + 9 * t))
        dens = ImageChops.multiply(dens, detail.point(lambda v: int(110 + v * 0.57)))
        dens = dens.point(lambda v, k=(1 - t) ** 1.2: int(min(255, v * 1.6) * k))
        # Shade: lighter at the top, darker underneath.
        shade = Image.linear_gradient("L").rotate(180).resize((C, C)).point(lambda v: int(150 + v * 0.42))
        rgb = Image.merge("RGB", [shade] * 3)
        rgba = rgb.copy()
        rgba.putalpha(dens)
        sheet.paste(rgba, ((f % 4) * C, (f // 4) * C))
    sheet.save(os.path.join(out, "smoke.png"))


def footprint(out):
    W, H = 128, 256
    a = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(a)
    d.ellipse([W * 0.22, H * 0.62, W * 0.78, H * 0.95], fill=255)  # heel
    d.ellipse([W * 0.15, H * 0.12, W * 0.85, H * 0.55], fill=255)  # forefoot
    d.rectangle([W * 0.3, H * 0.45, W * 0.68, H * 0.72], fill=200)  # arch (shoe)
    a = a.filter(ImageFilter.GaussianBlur(6))
    rim = a.filter(ImageFilter.GaussianBlur(10))
    hollow = a.point(lambda v: int(v * 0.85))
    # Albedo: dark in the hollow, light on the rim (pushed-up dry sand).
    rgb = Image.new("RGB", (W, H), (0, 0, 0))
    px, hp, rp = rgb.load(), hollow.load(), rim.load()
    for y in range(H):
        for x in range(W):
            h = hp[x, y] / 255.0
            r = max(0.0, rp[x, y] / 255.0 - h)
            v = 0.55 - 0.25 * h + 0.6 * r
            px[x, y] = (int(255 * min(v, 1)), int(235 * min(v, 1)), int(205 * min(v, 1)))
    alpha = ImageChops.lighter(hollow, rim.point(lambda v: int(v * 0.7)))
    rgb.putalpha(alpha)
    rgb.save(os.path.join(out, "footprint.png"))


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    spark_streak(out)
    impact(out)
    smoke(out)
    footprint(out)
    print("saved", out)
