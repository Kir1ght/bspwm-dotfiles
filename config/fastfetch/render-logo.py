#!/usr/bin/env python3
"""Render the Asuna torso crop as ANSI art for fastfetch.

Alacritty has neither sixel nor the kitty graphics protocol, so the picture has
to be text. A plain half-block render turns into a very chunky mosaic at the
size a fastfetch logo can afford. Instead this uses a hybrid:

* cells fully inside the artwork are drawn with U+2580 (two independent colors,
  so shading and gradients survive);
* cells on the silhouette edge are drawn with braille dots (2x4 sub-cells, so
  outlines and hair strands stay sharp).

The result is close to what chafa's "braille+block" mode does, but without an
extra dependency.

Art size is deliberately small and is clamped by both the terminal width and
height, so the module list never wraps and the logo never gets huge.
"""
import sys

from PIL import Image

src, out = sys.argv[1], sys.argv[2]
cols = int(sys.argv[3]) if len(sys.argv) > 3 else 100
lines = int(sys.argv[4]) if len(sys.argv) > 4 else 30

# Alacritty background (theme-colors.toml). Semi-transparent and pure-black
# wallpaper pixels are composited/mapped to it so they do not show up as black
# squares on the terminal background.
BG = (20, 19, 25)

# Hard cap on art width in cells: the logo should stay a logo, not turn into a
# full-screen wallpaper preview.
MAX_WIDTH = 38
# Longest module line is ~38 columns; plus logo padding (3) and a safety
# margin. Keeping this exact prevents fastfetch output from wrapping.
RESERVED = 44

DOTS = (
    (0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04),
    (1, 0, 0x08), (1, 1, 0x10), (1, 2, 0x20),
    (0, 3, 0x40), (1, 3, 0x80),
)

img = Image.open(src).convert("RGBA")
src_w, src_h = img.size


def cell_aspect():
    """Return cell width / cell height from the terminal, if it reports pixels."""
    import fcntl
    import os
    import struct
    import termios

    override = os.environ.get("FF_CELL_ASPECT")
    if override:
        return float(override)

    for fd in (1, 0, 2):
        try:
            rows, cols, xpix, ypix = struct.unpack(
                "HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
            )
        except OSError:
            continue
        if rows and cols and xpix and ypix:
            return (xpix / cols) / (ypix / rows)
    return 0.5


aspect = cell_aspect()
width = min(MAX_WIDTH, cols - RESERVED)
max_rows = max(4, lines - 3)
# Keep the picture's proportions: cells are not square in pixels.
width = max(12, min(width, int(max_rows * src_w / (src_h * aspect))))
height_cells = max(2, round(width * src_h / src_w * aspect))

# Sample at the braille dot grid: 2 dots across, 4 dots down per character.
img = img.resize((width * 2, height_cells * 4), Image.LANCZOS)


def visible(px):
    """Drop fully transparent pixels and the pure-black wallpaper background."""
    r, g, b, a = px
    return a >= 96 and (r > 10 or g > 10 or b > 10)


def avg(pxs):
    weight = sum(p[3] for p in pxs)
    if weight == 0:
        return None
    return (
        round(sum(p[0] * p[3] for p in pxs) / weight),
        round(sum(p[1] * p[3] for p in pxs) / weight),
        round(sum(p[2] * p[3] for p in pxs) / weight),
    )





rows = []
for cy in range(height_cells):
    line = []
    for cx in range(width):
        cell = [
            img.getpixel((cx * 2 + dx, cy * 4 + dy))
            for dx, dy, _ in DOTS
        ]
        lit = [p for p in cell if visible(p)]

        if not lit:
            line.append("\033[0m ")
            continue

        if len(lit) == 8:
            # Interior: two colors per character keeps gradients smooth.
            top = avg(cell[:4])
            bottom = avg(cell[4:])
            line.append(
                f"\033[38;2;{top[0]};{top[1]};{top[2]};"
                f"48;2;{bottom[0]};{bottom[1]};{bottom[2]}m\u2580"
            )
        else:
            # Silhouette: braille gives 2x4 sub-cell resolution.
            bits = 0
            for px, (_, _, bit) in zip(cell, DOTS):
                if visible(px):
                    bits |= bit
            color = avg(lit)
            line.append(
                f"\033[38;2;{color[0]};{color[1]};{color[2]}m"
                f"{chr(0x2800 + bits)}"
            )
    line.append("\033[0m")
    rows.append("".join(line))

with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(rows) + "\n")