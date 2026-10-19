#!/usr/bin/env python3
"""Rebuild Mochi's media package.

Reads the sprite grid and skin palettes from mochi-desktop/main.swift, so the
images always match the app. Run from anywhere:

    python3 media/build.py

Needs Pillow (`pip3 install pillow`). Writes only into media/.
"""
import pathlib
import re

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
MEDIA = ROOT / "media"
SWIFT = (ROOT / "mochi-desktop" / "main.swift").read_text()

HELVETICA = "/System/Library/Fonts/Helvetica.ttc"


def parse_grid():
    """The 16x16 letter grid, in source order."""
    block = SWIFT.split("let grid = [", 1)[1].split("]", 1)[0]
    rows = re.findall(r'"([^"]+)"', block)
    assert len(rows) == 16 and all(len(r) == 16 for r in rows), "grid is not 16x16"
    return rows


def parse_skins():
    """Each skin as (name, colours), where colours maps grid letters to hex."""
    pattern = re.compile(
        r'Skin\(name: "([^"]+)", palette: \[(.*?)\], face: NSColor\(hex: 0x\w+\), '
        r'eye: NSColor\(hex: 0x(\w+)\)\)',
        re.S,
    )
    skins = []
    for name, palette, eye in pattern.findall(SWIFT):
        colours = {k: "#" + v for k, v in re.findall(r'"(\w)": NSColor\(hex: 0x(\w+)\)', palette)}
        # Eyes use the skin's eye colour, shine is white (see mochi-desktop/main.swift, colour switch).
        colours.update({"E": "#" + eye, "e": "#" + eye, "W": "#FFFFFF"})
        skins.append((name, colours))
    assert len(skins) == 6, f"expected 6 skins, found {len(skins)}"
    return skins


def rgb(hex_colour):
    return tuple(int(hex_colour[i:i + 2], 16) for i in (1, 3, 5))


def render_cat(grid, colours, cell):
    """Draw the cat at `cell` pixels per square, on a transparent background."""
    img = Image.new("RGBA", (16 * cell, 16 * cell), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for y, row in enumerate(grid):
        for x, letter in enumerate(row):
            if letter in colours:
                draw.rectangle(
                    [x * cell, y * cell, (x + 1) * cell - 1, (y + 1) * cell - 1],
                    fill=rgb(colours[letter]) + (255,),
                )
    return img


def font(size, index=0):
    return ImageFont.truetype(HELVETICA, size, index=index)


def gradient(width, height, top, bottom):
    img = Image.new("RGB", (width, height), top)
    draw = ImageDraw.Draw(img)
    for y in range(height):
        t = y / (height - 1)
        colour = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (width, y)], fill=colour)
    return img


def save(img, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)
    print(f"wrote {path.relative_to(ROOT)} {img.size}")


def make_logo(grid, skins):
    classic = skins[0][1]
    save(render_cat(grid, classic, 64), MEDIA / "logo" / "mochi-logo-1024.png")
    for name, colours in skins:
        slug = re.sub(r"[^a-z]+", "-", name.lower()).strip("-")
        save(render_cat(grid, colours, 32), MEDIA / "logo" / "skins" / f"mochi-{slug}-512.png")


def make_skin_lineup(grid, skins):
    cell, pad, label_h = 14, 40, 50
    cat = 16 * cell
    cols, rows = 3, 2
    width = cols * (cat + 2 * pad)
    height = rows * (cat + 2 * pad + label_h)
    img = gradient(width, height, (250, 246, 240), (240, 232, 222))
    draw = ImageDraw.Draw(img)
    for i, (name, colours) in enumerate(skins):
        col, row = i % cols, i // cols
        x0 = col * (cat + 2 * pad) + pad
        y0 = row * (cat + 2 * pad + label_h) + pad
        img.paste(render_cat(grid, colours, cell), (x0, y0), render_cat(grid, colours, cell))
        label_font = font(26)
        w = draw.textlength(name, font=label_font)
        draw.text((x0 + (cat - w) / 2, y0 + cat + 14), name, fill=(60, 50, 45), font=label_font)
    save(img, MEDIA / "images" / "skins-lineup.png")


def make_gif():
    source = ROOT / "docs" / "mochi-working.gif"
    scale = 4
    frames, durations = [], []
    with Image.open(source) as gif:
        size = (gif.width * scale, gif.height * scale)
        for frame in range(gif.n_frames):
            gif.seek(frame)
            durations.append(gif.info.get("duration", 250))
            frames.append(gif.convert("RGBA").resize(size, Image.Resampling.NEAREST))
    out = MEDIA / "gif" / "mochi-working-4x.gif"
    out.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        out,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        disposal=2,
        optimize=True,
    )
    print(f"wrote {out.relative_to(ROOT)} {size}, {len(frames)} frames")


def make_social(grid, skins, width, height, name):
    classic = skins[0][1]
    img = gradient(width, height, (255, 247, 236), (255, 226, 190))
    draw = ImageDraw.Draw(img)
    cat_cell = int(height * 0.6) // 16
    cat = render_cat(grid, classic, cat_cell)
    img.paste(cat, (width - cat.width - int(width * 0.06), (height - cat.height) // 2), cat)

    left = int(width * 0.07)
    title_font = font(int(height * 0.2), index=1)
    sub_font = font(int(height * 0.075))
    small_font = font(int(height * 0.05))
    draw.text((left, int(height * 0.24)), "Mochi", fill=(59, 42, 32), font=title_font)
    draw.text((left, int(height * 0.50)), "A pixel-art companion for", fill=(59, 42, 32), font=sub_font)
    draw.text((left, int(height * 0.50) + int(height * 0.09)), "Claude Code on macOS", fill=(59, 42, 32), font=sub_font)
    draw.text((left, int(height * 0.82)), "github.com/EmmaNguyen/mod-pet", fill=(140, 90, 50), font=small_font)
    save(img, MEDIA / "social" / name)


def main():
    grid = parse_grid()
    skins = parse_skins()
    make_logo(grid, skins)
    make_skin_lineup(grid, skins)
    make_gif()
    make_social(grid, skins, 1280, 640, "github-social-1280x640.png")
    make_social(grid, skins, 1200, 630, "card-1200x630.png")


if __name__ == "__main__":
    main()
