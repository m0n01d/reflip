#!/usr/bin/env python3
"""Build a side-by-side comparison image: a Simulator/Safari screenshot next
to its matching design board render, for PR screenshots.

Usage:
    side-by-side.py <left_image> <right_image> <left_label> <right_label> <output_path>

Both inputs are scaled to a common width, cropped to one phone-screen worth
of height, labeled, and composited onto a single canvas.
"""
import sys

from PIL import Image, ImageDraw, ImageFont

TARGET_WIDTH = 780
CROP_HEIGHT = 1688
GAP = 32
MARGIN = 24
FONT_SIZE = 28
LABEL_GAP = 8  # padding between the label baseline area and the image below it
BG_COLOR = "#F3EFE6"
LABEL_COLOR = "#1B1813"
FONT_CANDIDATES = (
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
)


def scale_to_width(img: Image.Image, width: int) -> Image.Image:
    w, h = img.size
    new_h = round(h * width / w)
    return img.resize((width, new_h), Image.LANCZOS)


def crop_top(img: Image.Image, height: int) -> Image.Image:
    w, h = img.size
    return img.crop((0, 0, w, min(height, h)))


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main() -> None:
    if len(sys.argv) != 6:
        print(
            "usage: side-by-side.py <left> <right> <left-label> <right-label> <output>",
            file=sys.stderr,
        )
        sys.exit(1)

    left_path, right_path, left_label, right_label, out_path = sys.argv[1:6]

    left = crop_top(scale_to_width(Image.open(left_path).convert("RGB"), TARGET_WIDTH), CROP_HEIGHT)
    right = crop_top(scale_to_width(Image.open(right_path).convert("RGB"), TARGET_WIDTH), CROP_HEIGHT)

    font = load_font(FONT_SIZE)

    label_row_height = FONT_SIZE + LABEL_GAP
    canvas_w = MARGIN * 2 + TARGET_WIDTH * 2 + GAP
    canvas_h = MARGIN * 2 + label_row_height + CROP_HEIGHT

    canvas = Image.new("RGB", (canvas_w, canvas_h), BG_COLOR)
    draw = ImageDraw.Draw(canvas)

    left_x = MARGIN
    right_x = MARGIN + TARGET_WIDTH + GAP
    image_y = MARGIN + label_row_height

    draw.text((left_x, MARGIN), left_label, fill=LABEL_COLOR, font=font)
    draw.text((right_x, MARGIN), right_label, fill=LABEL_COLOR, font=font)

    canvas.paste(left, (left_x, image_y))
    canvas.paste(right, (right_x, image_y))

    canvas.save(out_path)
    print(out_path)


if __name__ == "__main__":
    main()
