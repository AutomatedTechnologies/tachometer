#!/usr/bin/env python3
"""Generate Tachometer's AppIcon.iconset — SDS-3 trimmed construction:
tile + glyph, NO black field. The glyph is a gauge (dial arc, ticks,
needle): one registered concept for this app, drawn once at 1024 and
downscaled so every rendition is the same composition (SDS-10 §10.1)."""
import math
from PIL import Image, ImageDraw

OUT = __file__.rsplit("/", 2)[0] + "/Tachometer/Resources/AppIcon.iconset"

SIZES = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}

def draw_master():
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Tile: light graphite plate, rounded, no black field.
    d.rounded_rectangle([28, 28, S - 28, S - 28], radius=190, fill=(232, 232, 232, 255))
    cx = cy = S / 2
    R = 330
    ink = (26, 26, 26, 255)
    # Dial arc: 270-degree sweep from 135deg to 405deg (gap at bottom).
    d.arc([cx - R, cy - R, cx + R, cy + R], start=135, end=405, fill=ink, width=44)
    # Ticks every 27 degrees along the sweep.
    for i in range(11):
        ang = math.radians(135 + i * 27)
        r1 = R - 58
        r2 = R - 118 if i % 5 == 0 else R - 96
        d.line([cx + r1 * math.cos(ang), cy + r1 * math.sin(ang),
                cx + r2 * math.cos(ang), cy + r2 * math.sin(ang)], fill=ink, width=26)
    # Needle at ~35 degrees into the sweep (upper right), hub at center.
    ang = math.radians(135 + 200)
    nx, ny = cx + (R - 90) * math.cos(ang), cy + (R - 90) * math.sin(ang)
    d.line([cx, cy, nx, ny], fill=ink, width=52)
    d.ellipse([cx - 62, cy - 62, cx + 62, cy + 62], fill=ink)
    return img

def main():
    import os
    os.makedirs(OUT, exist_ok=True)
    master = draw_master()
    for name, px in SIZES.items():
        master.resize((px, px), Image.LANCZOS).save(f"{OUT}/{name}")
        print("wrote", name, px)

if __name__ == "__main__":
    main()
