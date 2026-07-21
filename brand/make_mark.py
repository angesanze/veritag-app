#!/usr/bin/env python3
"""The Veritag mark — and every asset that carries it.

**L'impronta.** One tapered whorl coiling into a solid core, with two broken
ridges riding its outside. It is a fingerprint (the identity being vouched
for), a brushstroke (the hand that made the work) and the coil of an NFC
antenna (the chip that carries the proof) — the three things Veritag ties
together, drawn as one figure. The stroke cools to violet where it is widest
and warms to gold as it tightens into the core: the eye is pulled to the chip.

Geometry and palette live here and nowhere else. This script writes the SVG the
web surfaces embed and the PNGs the Android launcher uses; the Flutter painter
in mobile-app/lib/brand.dart mirrors the same constants by hand — change one,
change the other.

    python3 brand/make_mark.py     # needs Pillow

"""

from math import cos, radians, sin
from pathlib import Path

from PIL import Image, ImageDraw

# ── the figure, on a 64×64 canvas ───────────────────────────────────────────
BOX = 64.0
CX = CY = 32.0
CORE_R = 4.2
# (turns, radius out, radius in, start angle°, width out, width in)
RIDGES = [
    (1.85, 22.0, 6.5, 200, 5.8, 2.2),   # the whorl
    (0.50, 29.0, 26.5, 44, 4.4, 1.9),   # ridge, lower right
    (0.34, 29.0, 27.0, 196, 4.4, 1.9),  # ridge, upper left
]

# ── palette, shared with app and portal ─────────────────────────────────────
GRAD = ((18.0, 2.0), (46.0, 62.0))      # gradient axis in canvas units
STOPS = [(0.0, (124, 92, 255)),         # #7C5CFF
         (0.45, (154, 130, 255)),       # #9A82FF
         (1.0, (216, 180, 106))]        # #D8B46A
INK_BG = (8, 7, 13)                     # #08070D

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent


def spiral(turns, r_out, r_in, a0, n):
    """Points along an Archimedean spiral, outside first."""
    pts = []
    for i in range(n + 1):
        t = i / n
        a = radians(a0 + 360 * turns * t)
        r = r_out + (r_in - r_out) * t
        pts.append((CX + r * cos(a), CY + r * sin(a)))
    return pts


def outline(pts, w0, w1):
    """The two sides of a stroke of linearly varying width."""
    left, right = [], []
    n = len(pts) - 1
    for i, (x, y) in enumerate(pts):
        w = (w0 + (w1 - w0) * (i / n)) / 2
        if i == 0:
            dx, dy = pts[1][0] - x, pts[1][1] - y
        elif i == n:
            dx, dy = x - pts[-2][0], y - pts[-2][1]
        else:
            dx, dy = pts[i + 1][0] - pts[i - 1][0], pts[i + 1][1] - pts[i - 1][1]
        L = (dx * dx + dy * dy) ** 0.5 or 1.0
        nx, ny = -dy / L, dx / L
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))
    return left + right[::-1]


def _color_at(t):
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1 or t1 == 1.0:
            u = 0.0 if t1 == t0 else min(1.0, max(0.0, (t - t0) / (t1 - t0)))
            return tuple(round(a + (b - a) * u) for a, b in zip(c0, c1))
    return STOPS[-1][1]


def _gradient(size, inset):
    """The linear gradient of GRAD/STOPS, rasterised over the whole canvas."""
    (x0, y0), (x1, y1) = GRAD
    k = (size / BOX) * (1 - 2 * inset)
    off = size / 2 - CX * k
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
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    k = (s / BOX) * (1 - 2 * inset)
    off = s / 2 - CX * k

    def to_px(p):
        return (off + p[0] * k, off + p[1] * k)

    def dot(cx, cy, r):
        d.ellipse([off + (cx - r) * k, off + (cy - r) * k,
                   off + (cx + r) * k, off + (cy + r) * k], fill=255)

    for turns, r_out, r_in, a0, w0, w1 in RIDGES:
        pts = spiral(turns, r_out, r_in, a0, 220)
        d.polygon([to_px(p) for p in outline(pts, w0, w1)], fill=255)
        dot(*pts[0], w0 / 2)          # round caps, which PIL polygons lack
        dot(*pts[-1], w1 / 2)
    dot(CX, CY, CORE_R)

    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(_gradient(s, inset), (0, 0), mask)
    return out.resize((size, size), Image.LANCZOS)


def svg(size_attr=True):
    """The same figure as SVG — 48 samples a side is smooth past any size we use."""
    (x0, y0), (x1, y1) = GRAD
    body = []
    for turns, r_out, r_in, a0, w0, w1 in RIDGES:
        pts = spiral(turns, r_out, r_in, a0, 48)
        ring = outline(pts, w0, w1)
        d = "M" + "L".join(f"{x:.2f} {y:.2f}" for x, y in ring) + "Z"
        body.append(f'<path d="{d}"/>')
        for (px, py), w in ((pts[0], w0), (pts[-1], w1)):
            body.append(f'<circle cx="{px:.2f}" cy="{py:.2f}" r="{w / 2:.2f}"/>')
    body.append(f'<circle cx="{CX}" cy="{CY}" r="{CORE_R}"/>')
    stops = "".join(
        f'<stop offset="{o}" stop-color="#{r:02X}{g:02X}{b:02X}"/>' for o, (r, g, b) in STOPS)
    dim = ' width="64" height="64"' if size_attr else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"{dim} role="img" '
            f'aria-label="Veritag">\n'
            f'  <defs><linearGradient id="vt" x1="{x0}" y1="{y0}" x2="{x1}" y2="{y1}" '
            f'gradientUnits="userSpaceOnUse">{stops}</linearGradient></defs>\n'
            f'  <g fill="url(#vt)">\n    ' + "\n    ".join(body) + "\n  </g>\n</svg>\n")


def main():
    doc = svg()
    for p in [ROOT / "veritag-mark.svg", REPO / "web-portal/public/mark.svg", REPO / "landing/mark.svg"]:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(doc)

    res = REPO / "mobile-app/android/app/src/main/res"
    for folder, px in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
        # Adaptive foreground: 108dp canvas, figure inside the 72dp safe zone.
        render(round(px * 108 / 48), inset=0.18).save(res / f"mipmap-{folder}/ic_launcher_foreground.png")
        legacy = Image.new("RGBA", (px, px), INK_BG + (255,))
        legacy.alpha_composite(render(px, inset=0.14))
        legacy.convert("RGB").save(res / f"mipmap-{folder}/ic_launcher.png")
        # The splash draws this over the app's own near-black, never white.
        render(round(px * 2), inset=0.10).save(res / f"mipmap-{folder}/launch_image.png")

    store = Image.new("RGBA", (512, 512), INK_BG + (255,))
    store.alpha_composite(render(512, inset=0.14))
    store = store.convert("RGB")
    store.save(ROOT / "veritag-icon-512.png")
    for p in [REPO / "web-portal/public/icon-512.png", REPO / "landing/icon-512.png"]:
        store.save(p)   # apple-touch-icon and og:image
    print("wrote mark.svg + icon-512.png (brand, portal, landing), launcher icons, splash")


if __name__ == "__main__":
    main()
