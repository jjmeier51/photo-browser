#!/usr/bin/env python3
"""Draws the app icon — `photo_browser_icon.png`, 1024 px, which `build_app.sh` turns into the .icns.

    python3 mac/make_icon.py [out.png]

The iPhone app's icon is a wheel of colours round a folder; the Mac's is the same idea as the thing the app
shows: a 3 × 3 grid of photo tiles in those colours, with the folder as the middle tile, on a macOS-shaped
(rounded "squircle") light plate with its soft shadow. Drawn four times too big and scaled down, so the edges
are smooth. Needs Pillow only.
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE, SS = 1024, 4                       # the icon, and how much bigger it's drawn
PLATE = (100, 100, 924, 924)             # Apple's icon grid: an 824-px plate in a 1024-px canvas
# Round the grid, clockwise from the top left — the iPhone icon's wheel, as (top, bottom) of each tile.
TILES = [("#FF8A80", "#F4511E"), ("#FFC53D", "#FB8C00"), ("#F4E33A", "#D4C400"),
         ("#B4E05A", "#6CBF2A"), ("#5ED6A0", "#1FA96B"), ("#6FB7F2", "#2F7FD6"),
         ("#B29AE8", "#7E57C2"), ("#F08CC0", "#D6408C")]
RING = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]      # (column, row), clockwise


def rgb(c: str) -> tuple[int, int, int]:
    c = c.lstrip("#")
    return int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)


def squircle(box: tuple[float, float, float, float], n: float = 5.0) -> Image.Image:
    """An "L" mask the size of the big canvas with a superellipse filling `box` (macOS's icon shape, near enough)."""
    x0, y0, x1, y1 = [v * SS for v in box]
    cx, cy, a, b = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
    steps = 720
    import math
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + a * (abs(c) ** (2 / n)) * (1 if c >= 0 else -1),
                    cy + b * (abs(s) ** (2 / n)) * (1 if s >= 0 else -1)))
    mask = Image.new("L", (SIZE * SS, SIZE * SS), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask


def gradient(top: str, bottom: str) -> Image.Image:
    """The big canvas filled top to bottom from one colour to the other."""
    a, b = rgb(top), rgb(bottom)
    col = Image.new("RGB", (1, 256))
    col.putdata([tuple(round(a[k] + (b[k] - a[k]) * y / 255) for k in range(3)) for y in range(256)])
    return col.resize((SIZE * SS, SIZE * SS), Image.Resampling.BILINEAR)


def rounded(box: tuple[float, float, float, float], radius: float) -> Image.Image:
    mask = Image.new("L", (SIZE * SS, SIZE * SS), 0)
    ImageDraw.Draw(mask).rounded_rectangle([v * SS for v in box], radius * SS, fill=255)
    return mask


def boxed_gradient(top: str, bottom: str, box: tuple[float, float, float, float]) -> Image.Image:
    """A gradient that runs over `box` only (so each tile has its own, not a slice of the canvas's)."""
    a, b = rgb(top), rgb(bottom)
    h = max(2, int((box[3] - box[1]) * SS))
    col = Image.new("RGB", (1, h))
    col.putdata([tuple(round(a[k] + (b[k] - a[k]) * y / (h - 1)) for k in range(3)) for y in range(h)])
    out = Image.new("RGB", (SIZE * SS, SIZE * SS), a)
    out.paste(col.resize((int((box[2] - box[0]) * SS) + 1, h)), (int(box[0] * SS), int(box[1] * SS)))
    return out


def draw() -> Image.Image:
    big = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    plate = squircle(PLATE)
    # the plate's shadow: soft, a little below
    shadow = Image.new("RGBA", big.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), mask=ImageChops.offset(plate, 0, 14 * SS))
    big = Image.alpha_composite(big, shadow.filter(ImageFilter.GaussianBlur(22 * SS)))
    big.paste(gradient("#FFFFFF", "#E4E6EC"), mask=plate)
    # a hairline round the plate, so it holds its edge on a white Dock
    edge = ImageChops.subtract(plate, squircle((PLATE[0] + 2, PLATE[1] + 2, PLATE[2] - 2, PLATE[3] - 2)))
    big.paste((0, 0, 0, 26), mask=edge)

    inset, gap = 96, 34                                   # the grid inside the plate
    left, top = PLATE[0] + inset, PLATE[1] + inset
    side = (PLATE[2] - PLATE[0] - 2 * inset - 2 * gap) / 3
    radius = side * 0.24

    def cell(col: int, row: int) -> tuple[float, float, float, float]:
        x, y = left + col * (side + gap), top + row * (side + gap)
        return x, y, x + side, y + side

    for (colors, (c, r)) in zip(TILES, RING):
        box = cell(c, r)
        tile = rounded(box, radius)
        soft = Image.new("RGBA", big.size, (0, 0, 0, 0))                     # each tile sits a little off the plate
        soft.paste((0, 0, 0, 50), mask=ImageChops.offset(tile, 0, 5 * SS))
        big = Image.alpha_composite(big, soft.filter(ImageFilter.GaussianBlur(7 * SS)))
        big.paste(boxed_gradient(colors[0], colors[1], box), mask=tile)
        shine = rounded((box[0], box[1], box[2], box[1] + side * 0.5), radius)  # a lighter upper half, faint
        gloss = Image.new("RGBA", big.size, (255, 255, 255, 0))
        gloss.paste((255, 255, 255, 30), mask=ImageChops.multiply(shine, tile))
        big = Image.alpha_composite(big, gloss)

    # the middle tile: the folder
    x0, y0, x1, y1 = cell(1, 1)
    w, h = x1 - x0, y1 - y0
    back = Image.new("L", big.size, 0)
    d = ImageDraw.Draw(back)
    body = (x0 + w * 0.02, y0 + h * 0.20, x1 - w * 0.02, y1 - h * 0.08)
    d.rounded_rectangle([v * SS for v in body], w * 0.11 * SS, fill=255)
    tab = (body[0], y0 + h * 0.08, body[0] + w * 0.46, y0 + h * 0.40)
    d.rounded_rectangle([v * SS for v in tab], w * 0.10 * SS, fill=255)
    soft = Image.new("RGBA", big.size, (0, 0, 0, 0))
    soft.paste((0, 40, 120, 70), mask=ImageChops.offset(back, 0, 6 * SS))
    big = Image.alpha_composite(big, soft.filter(ImageFilter.GaussianBlur(8 * SS)))
    big.paste(boxed_gradient("#2E9BFF", "#1670E8", (x0, y0, x1, y1)), mask=back)
    front_box = (body[0], y0 + h * 0.34, body[2], body[3])
    front = rounded(front_box, w * 0.11)
    big.paste(boxed_gradient("#6CC4FF", "#2B8DF7", front_box), mask=front)
    return big.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("photo_browser_icon.png")
    draw().save(out)
    print("wrote", out)
