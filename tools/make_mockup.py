#!/usr/bin/env python3
"""Render a mockup of the watch face.

This is a DRAWING, not a screenshot. Nothing here runs Monkey C. It re-implements the
layout arithmetic of source/SolanaEpochView.mc in Python so the composition, the
proportions and the palette are faithful.

Font sizes prefer Garmin's simulator.json when present. Otherwise they fall back to
the values recovered from that file on 2026-09-23: fenix6 xtiny 13, tiny 18, small 20,
numberMedium 36, scaled for 240 and 280.

What it cannot be faithful about:
  - Typeface. The device uses Roboto Bold for text and Garmin's condensed "Bionic"
    family for numbers. Neither is on this box, so Arial Bold stands in. Real digits
    are narrower than these.
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
FONT_CANDIDATES = (
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
)

# The 64 colours a fenix 6 can show: every combination of 00/55/AA/FF per channel.
LEVELS = (0x00, 0x55, 0xAA, 0xFF)
PALETTE = [(r, g, b) for r in LEVELS for g in LEVELS for b in LEVELS]

# Fallback font pixel heights and screen size when the SDK device files are absent.
FALLBACK = {
    "fenix6": {"xtiny": 13, "tiny": 18, "small": 20, "numberMedium": 36, "size": (260, 260)},
    "fenix6s": {"xtiny": 12, "tiny": 16, "small": 18, "numberMedium": 32, "size": (240, 240)},
    "fenix6xpro": {"xtiny": 14, "tiny": 20, "small": 22, "numberMedium": 40, "size": (280, 280)},
}


def font_path():
    for path in FONT_CANDIDATES:
        if os.path.isfile(path):
            return path
    raise SystemExit("no bold sans font found")


FONT_PATH = font_path()


def device_fonts(device):
    """Nominal Graphics.FONT_* heights, from simulator.json or the recovered fallback."""
    path = os.path.expanduser(f"~/.Garmin/ConnectIQ/Devices/{device}/simulator.json")
    if os.path.isfile(path):
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
        comp = os.path.expanduser(f"~/.Garmin/ConnectIQ/Devices/{device}/compiler.json")
        with open(comp) as handle:
            res = json.load(handle)["resolution"]
        return sizes, (res["width"], res["height"])
    fb = FALLBACK[device]
    sizes = {k: v for k, v in fb.items() if k != "size"}
    return sizes, fb["size"]


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


def solana_mark(draw, cx, cy, w, colour):
    """Mirror of SolanaEpochView.drawSolanaMark."""
    h = (w * 7) // 10
    bar = max(3, h // 4)
    gap = max(3, h // 6)
    shear = w // 6
    left = cx - w // 2
    top = cy - h // 2

    def bar_poly(pts):
        draw.polygon(pts, fill=colour)

    bar_poly([
        (left + shear, top), (left + w, top),
        (left + w - shear, top + bar), (left, top + bar),
    ])
    mid = top + bar + gap
    bar_poly([
        (left + shear // 2, mid), (left + w - shear // 2, mid),
        (left + w - shear, mid + bar), (left, mid + bar),
    ])
    bot = mid + bar + gap
    bar_poly([
        (left, bot), (left + w - shear, bot),
        (left + w, bot + bar), (left + shear, bot + bar),
    ])


def palette_for(day):
    if day:
        return {
            "bg": (0xFF, 0xFF, 0xFF),
            "primary": (0x00, 0x00, 0x00),
            "secondary": (0x55, 0x55, 0x55),
            "track": (0xAA, 0xAA, 0xAA),
        }
    return {
        "bg": (0x00, 0x00, 0x00),
        "primary": (0xFF, 0xFF, 0xFF),
        "secondary": (0xAA, 0xAA, 0xAA),
        "track": (0x55, 0x55, 0x55),
    }


def render(device, state):
    sizes, (width, height) = device_fonts(device)
    pal = palette_for(state.get("day", True))
    image = Image.new("RGB", (width, height), pal["bg"])
    draw = ImageDraw.Draw(image)

    centre_x, centre_y = width // 2, height // 2
    radius = width // 2 - 5
    pen = max(6, width // 28)
    gap = max(3, width // 70)

    box = (centre_x - radius, centre_y - radius, centre_x + radius, centre_y + radius)
    draw.ellipse(box, outline=pal["track"], width=pen)

    sweep = int(state["progress"] * 360.0 + 0.5)
    if sweep >= 360:
        draw.ellipse(box, outline=state["accent"], width=pen)
    elif sweep > 0:
        draw.arc(box, start=270, end=270 + sweep, fill=state["accent"], width=pen)

    fonts = {name: (fitted_font(px), px) for name, px in sizes.items() if name in (
        "xtiny", "tiny", "small", "numberMedium")}

    xtiny, xtiny_px = fonts["xtiny"]
    tiny, tiny_px = fonts["tiny"]
    small, small_px = fonts["small"]
    clock_font, clock_px = fonts["numberMedium"]

    logo_w = max(22, width // 8)
    solana_mark(draw, centre_x, centre_y - int(height * 0.36), logo_w, pal["primary"])

    draw_row(draw, centre_x, centre_y - int(height * 0.28), xtiny, xtiny_px,
             state["date"], pal["secondary"])

    clock_centre = centre_y - int(height * 0.12)
    draw_row(draw, centre_x, clock_centre, clock_font, clock_px,
             state["clock"], pal["primary"])

    row_top = clock_centre + clock_px // 2 + gap
    draw_row(draw, centre_x, row_top + small_px // 2, small, small_px,
             state["epoch"], state["accent"])
    row_top += small_px + gap

    draw_row(draw, centre_x, row_top + tiny_px // 2, tiny, tiny_px,
             state["countdown"], pal["primary"])
    row_top += tiny_px + gap

    draw_row(draw, centre_x, row_top + xtiny_px // 2, xtiny, xtiny_px,
             state["status"], state["status_colour"])
    row_top += xtiny_px + gap * 2

    stats_x = int(width * 0.28)
    label_y = row_top + xtiny_px // 2
    value_y = row_top + xtiny_px + gap // 2 + tiny_px // 2
    draw_row(draw, centre_x - stats_x, label_y, xtiny, xtiny_px, "HR", pal["secondary"])
    draw_row(draw, centre_x - stats_x, value_y, tiny, tiny_px, state["hr"], pal["primary"])
    draw_row(draw, centre_x + stats_x, label_y, xtiny, xtiny_px, "STEPS", pal["secondary"])
    draw_row(draw, centre_x + stats_x, value_y, tiny, tiny_px, state["steps"], pal["primary"])

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
