#!/usr/bin/env python3
"""Turn the rendered screens into the pictures of the main README.

    python3 -I Tools/frame_screenshots.py RENDERED_FOLDER ../../docs/images/nnai

The input comes from ``SnapshotTests/testReadmeScreens``. Needs Pillow. Each picture is
converted to sRGB, resized to 1600 px, stripped of empty rows, given rounded corners and a
thin outline (so it stands apart on a light and on a dark page), and saved without metadata.
"""

import io
import sys

from PIL import Image, ImageCms, ImageDraw

WIDTH = 1600
OUTLINE = (205, 193, 180)
#: Rows of the resized picture where the window is empty, as (first, last) to cut out.
EMPTY_ROWS = {"add-books": (710, 990), "progress": (773, None)}


def to_srgb(image):
    profile = image.info.get("icc_profile")
    rgb = image.convert("RGB")
    if not profile:
        return rgb
    return ImageCms.profileToProfile(rgb, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                                     ImageCms.createProfile("sRGB"))


def without_rows(image, first, last):
    """``image`` without the rows from ``first`` to ``last`` (None: to the bottom)."""
    tail = image.height - last if last else 0
    result = Image.new("RGB", (image.width, first + tail))
    result.paste(image.crop((0, 0, image.width, first)), (0, 0))
    if tail:
        result.paste(image.crop((0, last, image.width, image.height)), (0, first))
    return result


def rounded(size, inset, radius, scale=4):
    width, height = size
    mask = Image.new("L", (width * scale, height * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [inset * scale, inset * scale, (width - inset) * scale - 1, (height - inset) * scale - 1],
        radius=radius * scale, fill=255)
    return mask.resize(size, Image.LANCZOS)


def frame(image, name):
    rgb = to_srgb(image)
    rgb = rgb.resize((WIDTH, round(rgb.height * WIDTH / rgb.width)), Image.LANCZOS)
    if name in EMPTY_ROWS:
        rgb = without_rows(rgb, *EMPTY_ROWS[name])
    outlined = Image.composite(rgb, Image.new("RGB", rgb.size, OUTLINE), rounded(rgb.size, 2, 20))
    result = outlined.convert("RGBA")
    result.putalpha(rounded(rgb.size, 0, 22))
    return result


def main(arguments):
    if len(arguments) != 2:
        print("usage: frame_screenshots.py RENDERED_FOLDER OUTPUT_FOLDER", file=sys.stderr)
        return 2
    source, target = arguments
    for name in ("add-books", "review", "progress", "library"):
        picture = frame(Image.open(f"{source}/{name}.png"), name)
        picture.save(f"{target}/{name}.png", optimize=True)
        print(f"{name}.png {picture.width}x{picture.height}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
