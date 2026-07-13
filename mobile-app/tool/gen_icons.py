"""Generate the ArtTrust launcher icon set (legacy PNGs + adaptive icon).

The mark mirrors the in-app brand: a rounded square swept by the violet→gold
gradient, carrying a serif "A" in the app's charcoal. Adaptive icons get the
badge floating on the charcoal background so round/squircle masks all look right.

    attestcore/.venv/bin/python consumers/arttrust/mobile-app/tool/gen_icons.py
"""
from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw, ImageFont

RES = pathlib.Path(__file__).resolve().parent.parent / "android/app/src/main/res"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"

VIOLET = (154, 130, 255)   # #9A82FF
GOLD = (216, 180, 106)     # #D8B46A
CHARCOAL = (8, 7, 13)      # #08070D — the app background

# launcher (legacy) and adaptive-foreground sizes per density
LAUNCHER = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
FOREGROUND = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

MASTER = 1024  # render large once, downscale with Lanczos


def gradient(size: int) -> Image.Image:
    """Diagonal violet→gold sweep."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    span = 2 * (size - 1) or 1
    for y in range(size):
        for x in range(size):
            t = (x + y) / span
            px[x, y] = tuple(round(VIOLET[i] + (GOLD[i] - VIOLET[i]) * t) for i in range(3))
    return img


def badge(size: int, radius_frac: float = 0.24) -> Image.Image:
    """The gradient rounded-square with the serif A."""
    img = gradient(size).convert("RGBA")
    # rounded-corner alpha mask
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * radius_frac), fill=255)
    img.putalpha(mask)
    # the A — nudged up slightly so it sits optically centered
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT, int(size * 0.60))
    draw.text((size / 2, size / 2 - size * 0.02), "A", font=font, fill=(*CHARCOAL, 255), anchor="mm")
    return img


def save(img: Image.Image, path: pathlib.Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path, "PNG")
    print(f"  {path.relative_to(RES)}  {size}px")


def main() -> None:
    master_badge = badge(MASTER)

    print("legacy launcher icons:")
    for density, size in LAUNCHER.items():
        save(master_badge, RES / f"mipmap-{density}/ic_launcher.png", size)

    # adaptive foreground: the badge floats in the middle ~60% of the canvas
    # (the OS masks the outer third), on a transparent layer.
    fg_master = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    inner = int(MASTER * 0.58)
    small = master_badge.resize((inner, inner), Image.LANCZOS)
    off = (MASTER - inner) // 2
    fg_master.paste(small, (off, off), small)

    print("adaptive foregrounds:")
    for density, size in FOREGROUND.items():
        save(fg_master, RES / f"mipmap-{density}/ic_launcher_foreground.png", size)

    (RES / "mipmap-anydpi-v26").mkdir(parents=True, exist_ok=True)
    (RES / "mipmap-anydpi-v26/ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        "</adaptive-icon>\n"
    )
    (RES / "values").mkdir(parents=True, exist_ok=True)
    (RES / "values/ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="ic_launcher_background">#08070D</color>\n'
        "</resources>\n"
    )
    print("adaptive icon xml + background color written")


if __name__ == "__main__":
    main()
