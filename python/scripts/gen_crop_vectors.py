"""Write shared/vectors/crop-vectors.json: the crop maths every app must match.

    python python/scripts/gen_crop_vectors.py shared/vectors/crop-vectors.json

(run from the repository root with python/src on PYTHONPATH). See shared/CROP.md.
"""

import json
import sys

from ulani_epaper import image

PHOTOS = [(1200, 900), (900, 1600), (4000, 3000), (1000, 600), (2560, 1080), (150, 90)]


def _crops(width: int, height: int) -> dict:
    left, top, w, h = image.default_crop(width, height)
    quarter = (w / 4, h / 4)
    return {
        "default": (left, top, w, h),
        "top-left": (0.0, 0.0, w, h),
        "bottom-right": (1 - w, 1 - h, w, h),
        "4x zoom centre": (0.5 - quarter[0] / 2, 0.5 - quarter[1] / 2, quarter[0], quarter[1]),
    }


def build() -> dict:
    crops = []
    invalid = []
    for width, height in PHOTOS:
        for name, crop in _crops(width, height).items():
            try:
                image.check_crop(crop, width, height)
            except ValueError as e:
                invalid.append({"photo": [width, height], "crop": list(crop), "name": name, "reason": str(e)})
                continue
            crops.append({"photo": [width, height], "name": name, "crop": list(crop),
                          "box": list(image.crop_box(crop, width, height))})
    # Half-pixel cases: floor(x + 0.5) rounds 250.5 up to 251 (round-half-to-even would give 250).
    boxes = [
        {"size": [1002, 604], "crop": [0.25, 0.125, 0.5, 0.5], "box": list(image.crop_box((0.25, 0.125, 0.5, 0.5), 1002, 604))},
        {"size": [1001, 601], "crop": [0.5, 0.5, 0.25, 0.25], "box": list(image.crop_box((0.5, 0.5, 0.25, 0.25), 1001, 601))},
        {"size": [3, 5], "crop": [0.5, 0.1, 0.5, 0.9], "box": list(image.crop_box((0.5, 0.1, 0.5, 0.9), 3, 5))},
    ]
    w, h = 1200, 900
    left, top, cw, ch = image.default_crop(w, h)
    for name, crop in {
        "outside the photo": (0.5, 0.0, cw, ch),
        "wrong shape": (0.0, 0.0, 0.5, 0.5),
        "negative": (-0.1, 0.1, cw, ch),
        "too small (beyond 8x zoom)": (0.4, 0.4, cw / 9, ch / 9),
    }.items():
        try:
            image.check_crop(crop, w, h)
        except ValueError as e:
            invalid.append({"photo": [w, h], "crop": list(crop), "name": name, "reason": str(e)})
        else:
            raise AssertionError(f"{name} should be rejected")
    return {
        "version": 1,
        "description": ("Crop maths (shared/CROP.md). crop = [left, top, width, height] as fractions of the "
                        "EXIF-oriented photo; box = [x0, y0, x1, y1] = floor(v * size + 0.5) (round half up). "
                        "'default' is the largest centred 800:480 rectangle (what Fill shows today). 'boxes' test "
                        "the rounding alone; 'invalid' crops must be rejected."),
        "screen": [image.WIDTH, image.HEIGHT],
        "min_crop_px": image.MIN_CROP_PX,
        "max_zoom": image.MAX_ZOOM,
        "crops": crops,
        "boxes": boxes,
        "invalid": invalid,
    }


if __name__ == "__main__":
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
