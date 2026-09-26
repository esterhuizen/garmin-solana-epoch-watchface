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


DRAW = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "resources", "drawables")


def paste_mark(image, cx, top, day):
    """Official logomark, top-aligned like SolanaEpochView.onUpdate."""
    name = "solana_mark_black.png" if day else "solana_mark_white.png"
    mark = Image.open(os.path.join(DRAW, name)).convert("RGBA")
    image.paste(mark, (cx - mark.width // 2, top), mark)
    return mark.height


def text_width(font, text):
    box = font.getbbox(text)
    return box[2] - box[0]


def icon_value_width(icon_name, text, font):
    icon = Image.open(os.path.join(DRAW, icon_name))
    return icon.width + 3 + text_width(font, text)


def chord_dx(inner, dy, half_w, half_h):
    reach_y = abs(dy) + half_h
    if reach_y >= inner:
        return 0
    chord = int((inner * inner - reach_y * reach_y) ** 0.5)
    dx = chord - half_w
    return dx if dx > 0 else 0


def draw_icon_value(image, draw, cx, y_centre, icon_name, text, font, height, colour):
    """Mirror of SolanaEpochView.drawIconValue: icon + text, group-centred."""
    icon = Image.open(os.path.join(DRAW, icon_name)).convert("RGBA")
    bbox = font.getbbox(text)
    text_w = bbox[2] - bbox[0]
    gap = 3
    total = icon.width + gap + text_w
    x = cx - total // 2
    image.paste(icon, (x, y_centre - icon.height // 2), icon)
    draw.text((x + icon.width + gap, y_centre - height // 2), text,
              font=font, fill=colour, anchor="la")


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

    inner = radius - (pen + 1) // 2 - 8
    gap = 3
    day = state.get("day", True)
    mark_bottom = centre_y - inner + 2
    mark_bottom += paste_mark(image, centre_x, mark_bottom, day)

    draw_row(draw, centre_x, mark_bottom + gap + xtiny_px // 2, xtiny, xtiny_px,
             state["date"], pal["secondary"])

    draw_row(draw, centre_x, centre_y, clock_font, clock_px,
             state["clock"], pal["primary"])

    heart = "heart_black.png" if day else "heart_white.png"
    shoe = "shoe_black.png" if day else "shoe_white.png"
    side_y = centre_y - int(height * 0.16)
    hr_dx = chord_dx(inner, side_y - centre_y,
                     icon_value_width(heart, state["hr"], small) // 2, small_px // 2)
    st_dx = chord_dx(inner, side_y - centre_y,
                     icon_value_width(shoe, state["steps"], small) // 2, small_px // 2)
    draw_icon_value(image, draw, centre_x - hr_dx, side_y, heart, state["hr"],
                    small, small_px, pal["primary"])
    draw_icon_value(image, draw, centre_x + st_dx, side_y, shoe, state["steps"],
                    small, small_px, pal["primary"])

    lower_y = centre_y + int(height * 0.18)
    sol = state.get("sol", "$--")
    epoch = state["epoch"]
    sol_dx = chord_dx(inner, lower_y - centre_y, text_width(small, sol) // 2, small_px // 2)
    ep_dx = chord_dx(inner, lower_y - centre_y, text_width(small, epoch) // 2, small_px // 2)
    draw_row(draw, centre_x - sol_dx, lower_y, small, small_px, sol, state["accent"])
    draw_row(draw, centre_x + ep_dx, lower_y, small, small_px, epoch, state["accent"])

    status_y = centre_y + inner - xtiny_px // 2 - 2
    count_y = status_y - xtiny_px // 2 - gap - tiny_px // 2
    draw_row(draw, centre_x, count_y, tiny, tiny_px,
             state["countdown"], pal["primary"])
    draw_row(draw, centre_x, status_y, xtiny, xtiny_px,
             state["status"], state["status_colour"])

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
