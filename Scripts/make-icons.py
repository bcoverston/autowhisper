#!/usr/bin/env python3
"""Generate autowhisper's app icon (.icns) and menu-bar template glyphs.

The mark: two waveforms — blue (microphone) from the left, orange (system
audio) from the right — converging into a single bright green node (the unified,
speaker-identified transcript). Menu-bar variants are monochrome templates the
system tints for light/dark/active states.

Run from the repo root:  python3 Scripts/make-icons.py
"""
import math
import os
import subprocess
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")
os.makedirs(RES, exist_ok=True)

BLUE = (88, 166, 255, 255)     # #58a6ff mic
ORANGE = (240, 136, 62, 255)   # #f0883e system
GREEN = (63, 185, 80, 255)     # #3fb950 matched
GREEN_HI = (86, 211, 100, 255)


def converging_bars(draw, cx, cy, span, base_bw, color_left, color_right, node_color, scale=1.0):
    """Draw symmetric waveform bars rising toward a central node."""
    n = 6                     # bars per side
    bw = base_bw
    gap = bw * 0.9
    # heights grow toward the center (converging)
    profile = [0.30, 0.42, 0.55, 0.70, 0.86, 1.0]
    unit = span
    for side in (-1, 1):
        color = color_left if side < 0 else color_right
        for i, p in enumerate(profile):
            # position: farthest bar first, closest to node last
            dist = (n - i) * (bw + gap)
            x = cx + side * dist
            h = unit * p
            draw.rounded_rectangle(
                [x - bw / 2, cy - h / 2, x + bw / 2, cy + h / 2],
                radius=bw / 2, fill=color)
    # central node
    nd = base_bw * 1.7
    draw.ellipse([cx - nd, cy - nd, cx + nd, cy + nd], fill=node_color)


def make_app_icon():
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = int(S * 0.086)
    r = int(S * 0.185)
    # dark phosphor tile with a subtle vertical gradient
    tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    td.rounded_rectangle([pad, pad, S - pad, S - pad], radius=r, fill=(13, 18, 26, 255))
    img.alpha_composite(tile)

    # soft green glow behind the node
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gr = int(S * 0.11)
    gd.ellipse([S // 2 - gr, int(S * 0.5) - gr, S // 2 + gr, int(S * 0.5) + gr],
               fill=(63, 185, 80, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(int(S * 0.05)))
    img.alpha_composite(glow)

    converging_bars(d, S // 2, int(S * 0.5), span=int(S * 0.34),
                    base_bw=int(S * 0.032), color_left=BLUE, color_right=ORANGE,
                    node_color=GREEN_HI)
    img.save(os.path.join(RES, "icon-1024.png"))

    # iconset → icns
    iconset = os.path.join(RES, "autowhisper.iconset")
    subprocess.run(["rm", "-rf", iconset], check=True)
    os.makedirs(iconset)
    for sz in (16, 32, 64, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            px = sz * scale
            out = os.path.join(iconset, f"icon_{sz}x{sz}{suffix}.png")
            img.resize((px, px), Image.LANCZOS).save(out)
    subprocess.run(["iconutil", "-c", "icns", iconset,
                    "-o", os.path.join(RES, "autowhisper.icns")], check=True)
    subprocess.run(["rm", "-rf", iconset], check=True)
    print("wrote Resources/autowhisper.icns + icon-1024.png")


def make_menubar_glyph(state):
    """Monochrome template glyph at 36px (18pt @2x), black on transparent.
    state: 'idle' (hollow node), 'auto' (hollow node + listening halo),
    'rec' (filled node)."""
    S = 36
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    black = (0, 0, 0, 255)
    cx, cy = S / 2, S / 2
    n = 3
    filled = state == "rec"
    bw = 3.0 if filled else 2.4
    gap = 3.4
    profile = [0.34, 0.62, 1.0]
    for side in (-1, 1):
        for i, p in enumerate(profile):
            dist = (n - i) * (bw + gap) - gap
            x = cx + side * dist
            h = S * 0.62 * p
            d.rounded_rectangle([x - bw / 2, cy - h / 2, x + bw / 2, cy + h / 2],
                                radius=bw / 2, fill=black)
    nd = 3.2 if filled else 2.6
    if filled:
        d.ellipse([cx - nd, cy - nd, cx + nd, cy + nd], fill=black)
    else:
        d.ellipse([cx - nd, cy - nd, cx + nd, cy + nd], outline=black, width=2)
    if state == "auto":
        # "listening" halo: a concentric ring around the node (always-on, armed).
        r = nd + 3.4
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=black, width=1)
    name = {"idle": "menubar-idle", "auto": "menubar-auto", "rec": "menubar-rec"}[state]
    img.save(os.path.join(RES, f"{name}.png"))
    print(f"wrote Resources/{name}.png")


if __name__ == "__main__":
    make_app_icon()
    for state in ("idle", "auto", "rec"):
        make_menubar_glyph(state)
