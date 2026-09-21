#!/usr/bin/env python3

import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont


def resolve_font(family):
    family = (family or "").strip()

    if not family or family.lower() in ("default", "sans-serif", "sans", "serif"):
        family = "sans-serif"

    try:
        out = subprocess.run(
            ["fc-match", "--format=%{file}", family],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        if out:
            return ImageFont.truetype(out, 15)
    except Exception:
        pass

    return ImageFont.load_default()


def main():
    text, px_raw, font_raw, color, angle_raw, out = sys.argv[1:7]

    px = int(px_raw)
    angle = int(angle_raw)
    font = resolve_font(font_raw)

    probe = Image.new("RGBA", (10, 10))
    draw = ImageDraw.Draw(probe)
    bbox = draw.textbbox((0, 0), text, font=font)

    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]

    image = Image.new("RGBA", (width + 8, height + 8), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.text((4 - bbox[0], 4 - bbox[1]), text, font=font, fill=color)

    image = image.rotate(angle, expand=True, resample=Image.BICUBIC)
    image.save(out, "PNG")
    print(out)


if __name__ == "__main__":
    main()