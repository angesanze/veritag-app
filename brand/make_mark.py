#!/usr/bin/env python3
"""The Veritag mark — and every asset that carries it.

**Il timbro.** A solid stamp with the tap carved out of its face: three
concentric waves cut into the block from the right, leaving a heavy left mass
and two arc bands. The gesture the whole product rests on — bringing a phone
close to a work — is not drawn *on* the mark, it is what has been taken *out*
of it. Violet where the mass is, gold where the last wave leaves.

The figure is a subtraction, which is why it survives being shrunk: at 18px the
silhouette still reads, and in one colour it still reads.

Geometry and palette live here and nowhere else. This script writes the SVG the
web surfaces embed and the PNGs the Android launcher uses; the Flutter painter
in mobile-app/lib/brand.dart mirrors the same constants by hand — change one,
change the other.

    python3 brand/make_mark.py     # needs Pillow

"""

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

# ── the figure, on a 64×64 canvas ───────────────────────────────────────────
BOX = 64.0
BLOCK = (5.0, 5.0, 59.0, 59.0)   # the stamp: square, generously rounded
RADIUS = 18.0
WAVE_C = (66.0, 32.0)            # waves are struck from off-canvas, to the right
# Radii, outside in, alternating cut / keep / cut / keep / cut.
WAVES = [38.0, 31.0, 23.0, 15.0, 7.0]

# ── palette, shared with app and portal ─────────────────────────────────────
GRAD = ((6.0, 4.0), (58.0, 60.0))       # gradient axis in canvas units
STOPS = [(0.0, (154, 130, 255)),        # #9A82FF
         (0.5, (124, 92, 255)),         # #7C5CFF
         (1.0, (216, 180, 106))]        # #D8B46A
INK_BG = (8, 7, 13)                     # #08070D

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent


def _color_at(t):
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1 or t1 == 1.0:
            u = 0.0 if t1 == t0 else min(1.0, max(0.0, (t - t0) / (t1 - t0)))
            return tuple(round(a + (b - a) * u) for a, b in zip(c0, c1))
    return STOPS[-1][1]


def _gradient(size, inset):
    (x0, y0), (x1, y1) = GRAD
    k = (size / BOX) * (1 - 2 * inset)
    off = size / 2 - (BOX / 2) * k
    ax, ay = (x1 - x0) * k, (y1 - y0) * k
    px0, py0 = off + x0 * k, off + y0 * k
    den = ax * ax + ay * ay
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = ((x - px0) * ax + (y - py0) * ay) / den
            px[x, y] = _color_at(min(1.0, max(0.0, t)))
    return g


def render(size, scale=8, inset=0.0):
    """The mark as RGBA; `inset` shrinks the figure inside its canvas."""
    s = size * scale
    k = (s / BOX) * (1 - 2 * inset)
    off = s / 2 - (BOX / 2) * k

    def box(cx, cy, r):
        return [off + (cx - r) * k, off + (cy - r) * k, off + (cx + r) * k, off + (cy + r) * k]

    # The block…
    block = Image.new("L", (s, s), 0)
    ImageDraw.Draw(block).rounded_rectangle(
        [off + BLOCK[0] * k, off + BLOCK[1] * k, off + BLOCK[2] * k, off + BLOCK[3] * k],
        radius=RADIUS * k, fill=255)

    # …minus the waves struck through it (alternating cut and keep, outside in).
    waves = Image.new("L", (s, s), 255)
    wd = ImageDraw.Draw(waves)
    for i, r in enumerate(WAVES):
        wd.ellipse(box(*WAVE_C, r), fill=0 if i % 2 == 0 else 255)

    mask = ImageChops.darker(block, waves)
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(_gradient(s, inset), (0, 0), mask)
    return out.resize((size, size), Image.LANCZOS)


def svg():
    """The same figure as SVG — a clip for the block, a mask for the waves."""
    (x0, y0), (x1, y1) = GRAD
    stops = "".join(
        f'<stop offset="{o}" stop-color="#{r:02X}{g:02X}{b:02X}"/>' for o, (r, g, b) in STOPS)
    cuts = "".join(
        f'<circle cx="{WAVE_C[0]:g}" cy="{WAVE_C[1]:g}" r="{r:g}" '
        f'fill="{"#000" if i % 2 == 0 else "#fff"}"/>'
        for i, r in enumerate(WAVES))
    bx, by, bx2, by2 = BLOCK
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64" '
        'role="img" aria-label="Veritag">\n'
        '  <defs>\n'
        f'    <linearGradient id="vt" x1="{x0:g}" y1="{y0:g}" x2="{x1:g}" y2="{y1:g}" '
        f'gradientUnits="userSpaceOnUse">{stops}</linearGradient>\n'
        f'    <clipPath id="vtblock"><rect x="{bx:g}" y="{by:g}" width="{bx2 - bx:g}" '
        f'height="{by2 - by:g}" rx="{RADIUS:g}"/></clipPath>\n'
        f'    <mask id="vtwaves"><rect width="64" height="64" fill="#fff"/>{cuts}</mask>\n'
        '  </defs>\n'
        '  <g clip-path="url(#vtblock)">\n'
        '    <rect width="64" height="64" fill="url(#vt)" mask="url(#vtwaves)"/>\n'
        '  </g>\n'
        '</svg>\n')


def main():
    doc = svg()
    for p in [ROOT / "veritag-mark.svg", REPO / "web-portal/public/mark.svg", REPO / "landing/mark.svg"]:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(doc)

    res = REPO / "mobile-app/android/app/src/main/res"
    for folder, px in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
        # Adaptive foreground: 108dp canvas, figure inside the 72dp safe zone.
        render(round(px * 108 / 48), inset=0.20).save(res / f"mipmap-{folder}/ic_launcher_foreground.png")
        legacy = Image.new("RGBA", (px, px), INK_BG + (255,))
        legacy.alpha_composite(render(px, inset=0.10))
        legacy.convert("RGB").save(res / f"mipmap-{folder}/ic_launcher.png")
        # The splash draws this over the app's own near-black, never white.
        render(round(px * 2), inset=0.08).save(res / f"mipmap-{folder}/launch_image.png")

    store = Image.new("RGBA", (512, 512), INK_BG + (255,))
    store.alpha_composite(render(512, inset=0.10))
    store = store.convert("RGB")
    store.save(ROOT / "veritag-icon-512.png")
    for p in [REPO / "web-portal/public/icon-512.png", REPO / "landing/icon-512.png"]:
        store.save(p)   # apple-touch-icon and og:image
    print("wrote mark.svg + icon-512.png (brand, portal, landing), launcher icons, splash")


if __name__ == "__main__":
    main()
