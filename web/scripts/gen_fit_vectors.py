"""Write shared/vectors/fit-vectors.json: the geometry of fitting pictures to
the panel and the colours of transparent pixels flattened onto white, for
web/src/core/fit.ts.

The expected values are recorded from the reference implementation, the
Python package in this repository (python/src/ulani_epaper; needs Pillow).
From the repository root:

    PYTHONPATH=python/src python web/scripts/gen_fit_vectors.py [OUT]

OUT defaults to shared/vectors/fit-vectors.json next to web/. The script
stops unless ulani_epaper is imported from this repository's python/src, so
a copy installed elsewhere is never recorded by mistake.

Only geometry is recorded, never resampled pixels (browsers and Pillow
resample differently). The reference's fit() is run on blank pictures while
its resize and paste calls are recorded:

- ``placements``: ``{"size": [w, h], "mode": m, "source": [l, t, r, b],
  "target": [x, y, w, h]}``. ``source`` is the box read from the picture
  (fractional for ``cover``), ``target`` where it lands on the 800 x 480 panel;
  the rest of the panel is white.
- ``flatten``: ``{"rgba": [r, g, b, a], "rgb": [r, g, b]}``, a pixel composited
  onto white.
"""

from __future__ import annotations

import json
import os
import sys

from PIL import Image

#: The reference package: python/src/ulani_epaper in this repository.
REFERENCE = os.path.realpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "python", "src", "ulani_epaper"))

try:
    from ulani_epaper import image as ref
except ModuleNotFoundError as error:
    if error.name != "ulani_epaper":
        raise
    sys.exit("ulani_epaper is not importable: run from the repository root with PYTHONPATH=python/src")

_imported = os.path.realpath(os.path.dirname(ref.__file__))
if os.path.normcase(_imported) != os.path.normcase(REFERENCE):
    sys.exit(f"ulani_epaper was imported from {_imported}, not from {REFERENCE}: "
             "run from the repository root with PYTHONPATH=python/src")

PANEL = (ref.WIDTH, ref.HEIGHT)

SIZES = [
    (800, 480), (1600, 960), (1000, 600), (400, 240),          # the panel's shape
    (4032, 3024), (3024, 4032), (1920, 1080), (1080, 1920),    # phone photos
    (4000, 3000), (6000, 4000), (640, 480), (480, 640),
    (801, 481), (799, 479), (801, 480), (800, 481),             # just off the shape
    (333, 200), (17, 13), (2, 1), (1, 2), (1, 1),               # small, scaled up
    (5, 960), (3, 960), (7, 960), (1600, 5), (1600, 3),         # halves: round to even
    (1, 10000), (10000, 1), (12345, 6789), (997, 1009),
]
MODES = ("contain", "cover", "stretch")


def placement(size: tuple[int, int], mode: str) -> dict:
    calls: list[tuple] = []
    resize, paste = Image.Image.resize, Image.Image.paste

    def recording_resize(self, new_size, resample=None, box=None, reducing_gap=None):
        calls.append(("resize", tuple(new_size), None if box is None else tuple(box), self.size))
        return Image.new(self.mode, tuple(new_size))

    def recording_paste(self, im, box=None, mask=None):
        calls.append(("paste", box, self.size))
        return paste(self, im, box, mask)

    Image.Image.resize, Image.Image.paste = recording_resize, recording_paste
    try:
        out = ref.fit(Image.new("RGB", size), mode)
    finally:
        Image.Image.resize, Image.Image.paste = resize, paste
    assert out.size == PANEL

    resizes = [c for c in calls if c[0] == "resize"]
    pastes = [c for c in calls if c[0] == "paste"]
    assert len(resizes) == 1, calls
    _, new_size, box, from_size = resizes[0]
    assert from_size == size, calls
    source = list(box) if box is not None else [0, 0, size[0], size[1]]
    if mode == "contain":
        assert len(pastes) == 1 and pastes[0][2] == PANEL, calls
        x, y = pastes[0][1]
        target = [x, y, new_size[0], new_size[1]]
    else:
        assert not pastes and new_size == PANEL, calls
        target = [0, 0, PANEL[0], PANEL[1]]
    return {"size": list(size), "mode": mode, "source": source, "target": target}


def flatten_cases() -> list[dict]:
    pixels = [
        (0, 0, 0, 0), (0, 0, 0, 255), (0, 0, 0, 128), (0, 0, 0, 127), (0, 0, 0, 1), (0, 0, 0, 254),
        (255, 255, 255, 0), (255, 0, 0, 128), (12, 200, 99, 77), (250, 125, 3, 200), (1, 2, 3, 4),
    ]
    for a in range(0, 256, 17):
        pixels.append((a, 255 - a, (a * 7) % 256, a))
    state = 0x51F7
    for _ in range(40):
        rgba = []
        for _ in range(4):
            state = (state * 1103515245 + 12345) & 0x7FFFFFFF
            rgba.append(state >> 23)
        pixels.append(tuple(rgba))
    img = Image.new("RGBA", (len(pixels), 1))
    img.putdata(pixels)
    flat = ref._to_rgb(img)
    assert flat.mode == "RGB"
    return [{"rgba": list(p), "rgb": list(flat.getpixel((i, 0)))} for i, p in enumerate(pixels)]


def build() -> dict:
    return {
        "version": 1,
        "description": ("Fitting pictures to the 800x480 panel. placements: source = box read from the "
                        "picture [left, top, right, bottom] (fractional for cover); target = where it lands "
                        "[x, y, width, height]; the rest of the panel is white. flatten: RGBA onto white."),
        "panel": list(PANEL),
        "placements": [placement(size, mode) for size in SIZES for mode in MODES],
        "flatten": flatten_cases(),
    }


def dumps(data: dict) -> str:
    lines = ["{"]
    keys = list(data)
    for n, key in enumerate(keys):
        comma = "," if n < len(keys) - 1 else ""
        value = data[key]
        if isinstance(value, list) and value and isinstance(value[0], dict):
            lines.append(f" {json.dumps(key)}: [")
            lines.extend(f"  {json.dumps(item)}{',' if m < len(value) - 1 else ''}" for m, item in enumerate(value))
            lines.append(f" ]{comma}")
        else:
            lines.append(f" {json.dumps(key)}: {json.dumps(value)}{comma}")
    lines.append("}")
    text = "\n".join(lines) + "\n"
    assert json.loads(text) == data
    return text


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    default = os.path.join(here, "..", "..", "shared", "vectors", "fit-vectors.json")
    out = os.path.normpath(sys.argv[1] if len(sys.argv) > 1 else default)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(build()))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
