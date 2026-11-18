#!/usr/bin/env python3
"""Generate the panda app icon and template sprite (Pillow, librsvg, macOS iconutil)."""
import io
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "docs/design/panda-marks"


def render(svg, size):
    data = subprocess.check_output(["rsvg-convert", "-w", str(size), "-h", str(size)], input=svg)
    return Image.open(io.BytesIO(data)).convert("RGBA")


def main():
    canvas = Image.new("RGBA", (1024, 1024))
    tile = render((ART / "desk-app-icon.svg").read_bytes(), 1024)
    tile = tile.crop(tile.getbbox()).resize((824, 824), Image.Resampling.LANCZOS)
    canvas.alpha_composite(tile, (100, 100))
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "Muster.iconset"
        iconset.mkdir()
        for pts in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                size = pts * scale
                canvas.resize((size, size), Image.Resampling.LANCZOS).save(iconset / f"icon_{pts}x{pts}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", ROOT / "Resources/AppIcon.icns"], check=True)

    source = (ART / "desk-menubar-icon.svg").read_bytes()
    heights = (1, .75, .4, .19, .4, .75, 1)
    side = 96
    strip = Image.new("RGBA", (side * len(heights), side))
    for i, height in enumerate(heights):
        svg = ET.fromstring(source)
        for eye in svg.findall("{http://www.w3.org/2000/svg}ellipse"):
            cy = eye.attrib["cy"]
            eye.set("transform", f"{eye.attrib['transform']} translate(0 {cy}) scale(1 {height}) translate(0 -{cy})")
        strip.paste(render(ET.tostring(svg), side), (i * side, 0))
    strip.save(ROOT / "Sources/Muster/Resources/panda-blink.png")


if __name__ == "__main__":
    main()
