#!/usr/bin/env python3
"""Render a mockup of the watch face.

This is a DRAWING, not a screenshot. Nothing here runs Monkey C. It re-implements the
layout arithmetic of source/SolanaEpochView.mc in Python so the composition, the
proportions and the palette are faithful, and it uses the real per-device font sizes that
Garmin ships in ~/.Garmin/ConnectIQ/Devices/<id>/simulator.json.

What it cannot be faithful about:
  - Typeface. The device uses Roboto Bold for text and Garmin's condensed "Bionic" family
    for numbers. Neither is on this box, so DejaVu Sans Bold stands in. Real digits are
    narrower than these.
  - Antialiasing. fenix 6 reports alphaBlendingSupport = false, so real text has hard
    edges. Pillow antialiases; the palette snap below claws most of that back, but not
    all.
  - The exact vertical placement of the clock row, which is the one thing flagged as
    unverified in docs/VERIFICATION.md.
"""
import json
import os
import sys
from PIL import Image, ImageDraw, ImageFont

DEVICES = ("fenix6", "fenix6s", "fenix6xpro")
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# The 64 colours a fenix 6 can show: every combination of 00/55/AA/FF per channel.
LEVELS = (0x00, 0x55, 0xAA, 0xFF)
PALETTE = [(r, g, b) for r in LEVELS for g in LEVELS for b in LEVELS]

# Se.* constants from source/SolanaEpochApp.mc
COLOR_BG = (0x00, 0x00, 0x00)
COLOR_PRIMARY = (0xFF, 0xFF, 0xFF)
COLOR_SECONDARY = (0xAA, 0xAA, 0xAA)
COLOR_TRACK = (0x55, 0x55, 0x55)
COLOR_WARNING = (0xFF, 0xAA, 0x00)
DEFAULT_ACCENT = (0xAA, 0x55, 0xFF)


def device_fonts(device):
    """Nominal Graphics.FONT_* heights, straight out of Garmin's simulator config."""
    path = os.path.expanduser(f"~/.Garmin/ConnectIQ/Devices/{device}/simulator.json")
    with open(path) as handle:
        sim = json.load(handle)
    sizes = {}
    for group in sim["fonts"]:
        if group["fontSet"] != "ww":
            continue
        for font in group["fonts"]:
            tail = font["filename"].rsplit("_", 1)[-1].rstrip("B")
            if tail.isdigit():
                sizes[font["name"]] = int(tail)
    # Screen size comes from compiler.json, which is the authoritative device record;
    # simulator.json nests it under display.location alongside window coordinates.
    comp = os.path.expanduser(f"~/.Garmin/ConnectIQ/Devices/{device}/compiler.json")
    with open(comp) as handle:
        res = json.load(handle)["resolution"]
    return sizes, (res["width"], res["height"])


def fitted_font(target_height):
    """A Pillow font whose ascent+descent is as close as possible to target_height."""
    best, best_error = None, None
    for size in range(4, target_height * 3):
        font = ImageFont.truetype(FONT_PATH, size)
        ascent, descent = font.getmetrics()
        error = abs((ascent + descent) - target_height)
        if best_error is None or error < best_error:
            best, best_error = font, error
    return best


def draw_row(draw, centre_x, y_centre, font, height, text, colour):
    """Mirror of SolanaEpochView.drawRow: centre the font box on y_centre."""
    top = y_centre - height // 2
    draw.text((centre_x, top), text, font=font, fill=colour, anchor="ma")


def render(device, state):
    sizes, (width, height) = device_fonts(device)
    image = Image.new("RGB", (width, height), COLOR_BG)
    draw = ImageDraw.Draw(image)

    # --- geometry, integer maths exactly as the Monkey C does it ---
    centre_x, centre_y = width // 2, height // 2
    radius = width // 2 - 5
    pen = max(6, width // 28)
    gap = max(3, width // 70)

    box = (centre_x - radius, centre_y - radius, centre_x + radius, centre_y + radius)
    draw.ellipse(box, outline=COLOR_TRACK, width=pen)

    # Garmin: 0 deg is 3 o'clock and 90 is 12 o'clock, swept clockwise. Pillow measures
    # clockwise from 3 o'clock because y grows downward, so 12 o'clock is 270 there.
    sweep = int(state["progress"] * 360.0 + 0.5)
    if sweep >= 360:
        draw.ellipse(box, outline=state["accent"], width=pen)
    elif sweep > 0:
        draw.arc(box, start=270, end=270 + sweep, fill=state["accent"], width=pen)

    fonts = {name: (fitted_font(px), px) for name, px in sizes.items()}

    xtiny, xtiny_px = fonts["xtiny"]
    tiny, tiny_px = fonts["tiny"]
    small, small_px = fonts["small"]
    clock_font, clock_px = fonts["numberMedium"]

    draw_row(draw, centre_x, centre_y - int(height * 0.27), xtiny, xtiny_px,
             state["date"], COLOR_SECONDARY)

    clock_centre = centre_y - int(height * 0.09)
    draw_row(draw, centre_x, clock_centre, clock_font, clock_px,
             state["clock"], COLOR_PRIMARY)

    row_top = clock_centre + clock_px // 2 + gap
    draw_row(draw, centre_x, row_top + small_px // 2, small, small_px,
             state["epoch"], state["accent"])
    row_top += small_px + gap

    draw_row(draw, centre_x, row_top + tiny_px // 2, tiny, tiny_px,
             state["countdown"], COLOR_PRIMARY)
    row_top += tiny_px + gap

    draw_row(draw, centre_x, row_top + xtiny_px // 2, xtiny, xtiny_px,
             state["status"], state["status_colour"])

    # --- snap to the 64-colour palette, and mask to the round display ---
    flat = [c for colour in PALETTE for c in colour]
    reference = Image.new("P", (1, 1))
    reference.putpalette(flat + [0] * (768 - len(flat)))
    image = image.quantize(palette=reference, dither=Image.Dither.NONE).convert("RGB")

    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, width - 1, height - 1), fill=255)
    out = Image.new("RGB", (width, height), (0x22, 0x22, 0x22))
    out.paste(image, (0, 0), mask)
    return out


def main():
    state = json.load(open(sys.argv[1]))
    for key in ("accent", "status_colour"):
        state[key] = tuple(state[key])
    out_dir = sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    for device in DEVICES:
        image = render(device, state)
        path = os.path.join(out_dir, f"mockup-{device}.png")
        image.save(path)
        print(f"{path}  {image.width}x{image.height}")

    # A 3-up strip, each face scaled 2x, to show one layout covering three screen sizes.
    scaled = [render(d, state).resize((render(d, state).width * 2,) * 2, Image.NEAREST)
              for d in DEVICES]
    pad = 24
    strip = Image.new("RGB",
                      (sum(i.width for i in scaled) + pad * (len(scaled) + 1),
                       max(i.height for i in scaled) + pad * 2),
                      (0x11, 0x11, 0x11))
    x = pad
    for image in scaled:
        strip.paste(image, (x, pad + (strip.height - pad * 2 - image.height) // 2))
        x += image.width + pad
    path = os.path.join(out_dir, "mockup-all-sizes.png")
    strip.save(path)
    print(f"{path}  {strip.width}x{strip.height}")


if __name__ == "__main__":
    main()
