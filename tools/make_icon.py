#!/usr/bin/env python3
"""Generate launcher_icon.png and the on-face Solana logomark bitmaps.

The logomark is the official asset from solana.com/branding
(https://solana.com/src/img/branding/solanaLogoMark.svg), stored as
tools/solanaLogoMark.svg. Do not redraw it. fenix 6 has no alpha blending, so
every bitmap is hard-edged and snapped to the 64-colour palette (marks are
1-bit: ink or transparent).

Run from the project root:

    python3 tools/make_icon.py
"""

import os
import subprocess
import tempfile

from PIL import Image, ImageDraw

SIZE = 40
SCALE = 8
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRAW = os.path.join(ROOT, "resources", "drawables")
SVG = os.path.join(ROOT, "tools", "solanaLogoMark.svg")

LEVELS = (0x00, 0x55, 0xAA, 0xFF)

BG = (0xFF, 0xFF, 0xFF)
TRACK = (0x00, 0x00, 0x00)
ACCENT = (0xAA, 0x55, 0xFF)
LOGO = (0x00, 0x00, 0x00)

# On-face mark. 32x28 is 101:88 (official viewBox) and fits 240/260/280
# without drawScaledBitmap (CIQ 3.4 does not have it).
MARK_W = 32
MARK_H = 28

PROGRESS = 0.72


def snap(value):
    """Snap one 0..255 channel to the nearest of 00/55/AA/FF."""
    return min(LEVELS, key=lambda level: abs(level - value))


def render_mark(ink, width, height, oversample=8):
    """Rasterise the official SVG to a hard-edged ink-on-transparent RGBA image."""
    big_w, big_h = width * oversample, height * oversample
    svg = open(SVG).read().replace("<path ", '<path fill="{}" '.format(
        "#FFFFFF" if ink == (255, 255, 255) else "#000000"
    ))
    with tempfile.TemporaryDirectory() as tmp:
        svg_path = os.path.join(tmp, "mark.svg")
        png_path = os.path.join(tmp, "mark.png")
        open(svg_path, "w").write(svg)
        subprocess.check_call([
            "rsvg-convert", "-w", str(big_w), "-h", str(big_h),
            "-o", png_path, svg_path,
        ])
        image = Image.open(png_path).convert("RGBA")
    # Hard threshold: fenix 6 cannot blend. Keep ink or drop the pixel.
    pixels = []
    for r, g, b, a in image.getdata():
        if a >= 128:
            pixels.append(ink + (255,))
        else:
            pixels.append((0, 0, 0, 0))
    image.putdata(pixels)
    image = image.resize((width, height), Image.NEAREST)
    return image


def write_mark(ink, name):
    image = render_mark(ink, MARK_W, MARK_H)
    path = os.path.join(DRAW, name)
    image.save(path, "PNG", optimize=True)
    print("wrote {} ({}x{})".format(path, MARK_W, MARK_H))


def main():
    write_mark((0x00, 0x00, 0x00), "solana_mark_black.png")
    write_mark((0xFF, 0xFF, 0xFF), "solana_mark_white.png")

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

    mark = render_mark(LOGO, 18 * SCALE, 16 * SCALE, oversample=1)
    mx = (big - mark.width) // 2
    my = (big - mark.height) // 2
    image.paste(mark, (mx, my), mark)

    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    image = Image.merge("RGB", [chan.point(snap) for chan in image.split()])
    out = os.path.join(DRAW, "launcher_icon.png")
    image.save(out, "PNG", optimize=True)

    palette = sorted(colour for _count, colour in image.getcolors(maxcolors=4096))
    print("wrote {} ({}x{}, {} distinct colours)".format(out, SIZE, SIZE, len(palette)))
    for colour in palette:
        print("  #{:02X}{:02X}{:02X}".format(*colour))


if __name__ == "__main__":
    main()
