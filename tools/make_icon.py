#!/usr/bin/env python3
"""Generate resources/drawables/launcher_icon.png.

The fenix 6 family declares a 40x40 launcherIcon and an 8 bpp MIP display whose
palette is every combination of 00/55/AA/FF per channel (64 colours), with no alpha
blending. So the icon is drawn 8x oversampled, downsampled for smooth edges, and then
every pixel is snapped to the nearest palette entry -- otherwise the device dithers it.

Daytime brand: white field, black Solana mark, purple epoch arc. A white-on-black
mark disappears on the light face and in the Connect IQ launcher against light tiles.

Run from the project root:

    python3 tools/make_icon.py
"""

import os

from PIL import Image, ImageDraw

SIZE = 40
SCALE = 8
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "resources", "drawables", "launcher_icon.png",
)

LEVELS = (0x00, 0x55, 0xAA, 0xFF)

BG = (0xFF, 0xFF, 0xFF)
TRACK = (0x00, 0x00, 0x00)
ACCENT = (0xAA, 0x55, 0xFF)  # nearest palette entry to Solana purple 0x9945FF
LOGO = (0x00, 0x00, 0x00)

# Fraction of the ring the accent arc covers.
PROGRESS = 0.72


def snap(value):
    """Snap one 0..255 channel to the nearest of 00/55/AA/FF."""
    return min(LEVELS, key=lambda level: abs(level - value))


def solana_bars(draw, cx, cy, w, fill):
    """Three sheared parallelograms, the Solana mark, centred on (cx, cy)."""
    h = (w * 7) // 10
    bar = max(3, h // 4)
    gap = max(3, h // 6)
    shear = w // 6
    left = cx - w // 2
    top = cy - h // 2

    def bar_poly(x1, y1, x2, y2, x3, y3, x4, y4):
        draw.polygon([(x1, y1), (x2, y2), (x3, y3), (x4, y4)], fill=fill)

    bar_poly(left + shear, top, left + w, top, left + w - shear, top + bar, left, top + bar)
    mid = top + bar + gap
    bar_poly(
        left + shear // 2, mid, left + w - shear // 2, mid,
        left + w - shear, mid + bar, left, mid + bar,
    )
    bot = mid + bar + gap
    bar_poly(left, bot, left + w - shear, bot, left + w, bot + bar, left + shear, bot + bar)


def main():
    big = SIZE * SCALE
    image = Image.new("RGB", (big, big), BG)
    draw = ImageDraw.Draw(image)

    margin = 1 * SCALE
    draw.ellipse([margin, margin, big - margin - 1, big - margin - 1], fill=BG)

    ring = 5 * SCALE
    box = [ring, ring, big - ring - 1, big - ring - 1]
    width = 4 * SCALE
    draw.arc(box, start=0, end=360, fill=TRACK, width=width)
    draw.arc(box, start=-90, end=-90 + 360.0 * PROGRESS, fill=ACCENT, width=width)

    solana_bars(draw, big // 2, big // 2, 14 * SCALE, LOGO)

    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    image = Image.merge("RGB", [chan.point(snap) for chan in image.split()])
    image.save(OUT, "PNG", optimize=True)

    palette = sorted(colour for _count, colour in image.getcolors(maxcolors=4096))
    print("wrote {} ({}x{}, {} distinct colours)".format(OUT, SIZE, SIZE, len(palette)))
    for colour in palette:
        print("  #{:02X}{:02X}{:02X}".format(*colour))


if __name__ == "__main__":
    main()
