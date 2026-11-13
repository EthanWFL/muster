#!/usr/bin/env python3
"""Generates Resources/AppIcon.icns from the manta mark.

    python3 Scripts/make-icon.py        # needs Pillow: python3 -m pip install Pillow

The mark is a frame of manta-glide.gif, so the icon always matches the brand art.
1024px canvas, squircle 824x824 at 100px margin (macOS Big Sur+ grid).
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/Muster/Resources/manta-glide.gif"
OUTPUT = ROOT / "Resources/AppIcon.icns"

CANVAS, SIDE, MARGIN, RADIUS = 1024, 824, 100, 185
TOP, BOTTOM = (99, 90, 241), (60, 51, 196)


def mark() -> Image.Image:
    """白色蝠鲼剪影：alpha 当形状，内部的白色 V 形从剪影里挖掉。"""
    gif = Image.open(SOURCE)
    best = max(
        (frame.convert("RGBA") for frame in _frames(gif)),
        key=lambda f: (lambda b: (b[2] - b[0]) * (b[3] - b[1]))(f.split()[3].getbbox()),
    )
    pixels = best.load()
    mask = Image.new("L", best.size, 0)
    target = mask.load()
    for y in range(best.size[1]):
        for x in range(best.size[0]):
            r, g, b, a = pixels[x, y]
            if a > 128 and not (r > 200 and g > 200 and b > 200):
                target[x, y] = 255
    # 菜单栏静态图（MenuBarIcon）的尾巴向右弯；这一帧向左，翻转后两者一致
    return mask.crop(mask.getbbox()).transpose(Image.FLIP_LEFT_RIGHT)


def _frames(gif):
    for i in range(getattr(gif, "n_frames", 1)):
        gif.seek(i)
        yield gif


def icon(mark_image: Image.Image) -> Image.Image:
    squircle = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(squircle).rounded_rectangle(
        [MARGIN, MARGIN, CANVAS - MARGIN, CANVAS - MARGIN], radius=RADIUS, fill=255
    )
    gradient = Image.new("RGBA", (CANVAS, CANVAS))
    painter = ImageDraw.Draw(gradient)
    for y in range(CANVAS):
        t = y / CANVAS
        painter.line(
            [(0, y), (CANVAS, y)],
            fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) + (255,),
        )
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(gradient, (0, 0), squircle)

    height = round(SIDE * 0.56)
    width = round(mark_image.size[0] * height / mark_image.size[1])
    scaled = mark_image.resize((width, height), Image.LANCZOS)
    canvas.paste((255, 255, 255, 255), ((CANVAS - width) // 2, MARGIN + (SIDE - height) // 2), scaled)
    return canvas


def main() -> int:
    art = icon(mark())
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "Muster.iconset"
        iconset.mkdir()
        for name, size in [
            ("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128),
            ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024),
        ]:
            art.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{name}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUTPUT)], check=True)
    print(f"wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
