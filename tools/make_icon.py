#!/usr/bin/env python3
"""Generate resources/drawables/launcher_icon.png.

The fenix 6 family declares a 40x40 launcherIcon and an 8 bpp MIP display whose
palette is every combination of 00/55/AA/FF per channel (64 colours), with no alpha
blending. So the icon is drawn 8x oversampled, downsampled for smooth edges, and then
every pixel is snapped to the nearest palette entry -- otherwise the device dithers it.

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

BG = (0x00, 0x00, 0x00)
TRACK = (0x55, 0x55, 0x55)
ACCENT = (0xAA, 0x55, 0xFF)  # nearest palette entry to Solana purple 0x9945FF

# Fraction of the ring the accent arc covers.
PROGRESS = 0.72


def snap(value):
    """Snap one 0..255 channel to the nearest of 00/55/AA/FF."""
    return min(LEVELS, key=lambda level: abs(level - value))


def main():
    big = SIZE * SCALE
    image = Image.new("RGB", (big, big), BG)
    draw = ImageDraw.Draw(image)

    # Dark disc, so the icon reads as a watch face rather than a floating ring.
    margin = 1 * SCALE
    draw.ellipse([margin, margin, big - margin - 1, big - margin - 1], fill=BG)

    # Ring track, then the epoch arc over it. 0 degrees is 3 o'clock in PIL too, and
    # the arc starts at 12 o'clock (-90) and runs clockwise, matching the watch face.
    ring = 5 * SCALE
    box = [ring, ring, big - ring - 1, big - ring - 1]
    width = 5 * SCALE
    draw.arc(box, start=0, end=360, fill=TRACK, width=width)
    draw.arc(box, start=-90, end=-90 + 360.0 * PROGRESS, fill=ACCENT, width=width)

    # Centre dot, the "now" marker.
    dot = 6 * SCALE
    draw.ellipse(
        [big // 2 - dot // 2, big // 2 - dot // 2, big // 2 + dot // 2, big // 2 + dot // 2],
        fill=ACCENT,
    )

    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    image = Image.merge("RGB", [chan.point(snap) for chan in image.split()])
    image.save(OUT, "PNG", optimize=True)

    palette = sorted(colour for _count, colour in image.getcolors(maxcolors=4096))
    print("wrote {} ({}x{}, {} distinct colours)".format(OUT, SIZE, SIZE, len(palette)))
    for colour in palette:
        print("  #{:02X}{:02X}{:02X}".format(*colour))


if __name__ == "__main__":
    main()
