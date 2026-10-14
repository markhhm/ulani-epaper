"""Natural dithering against shared/vectors/natural-vectors.json (shared/DITHER.md §6).

The vectors are made by python/tools/natural_vectors.py; from the repository root:

    PYTHONPATH=python/src python python/tools/natural_vectors.py

and the tables by python/tools/natural_tables.py (needs numpy).
"""

import base64
import hashlib
import json
import random
import struct
import zlib
from importlib import resources
from pathlib import Path

import pytest
from PIL import Image

from ulani_epaper import image

SHARED = Path(__file__).resolve().parents[2] / "shared"
TABLES = SHARED / "dither" / "natural-tables.json"
VECTORS = json.loads((SHARED / "vectors" / "natural-vectors.json").read_text(encoding="utf-8"))


def _digest(values) -> str:
    flat = []

    def walk(v):
        if isinstance(v, list):
            for x in v:
                walk(x)
        else:
            flat.append(v)

    walk(values)
    return hashlib.sha256(b"".join(struct.pack("<d", v) for v in flat)).hexdigest()


def _image(case) -> Image.Image:
    return Image.frombytes("RGB", (case["width"], case["height"]), bytes.fromhex(case["rgb"]))


def test_the_package_ships_the_shared_tables():
    packaged = (resources.files("ulani_epaper") / "data" / "natural-tables.json").read_bytes()
    assert packaged == TABLES.read_bytes()  # rerun python/tools/natural_tables.py, which writes both


def test_tables_parse_to_the_pinned_doubles():
    raw = json.loads(TABLES.read_text(encoding="utf-8"))
    parsed = image.natural_tables()
    pinned = VECTORS["tables_sha256"]
    integers = {"palette_srgb", "sectors", "stucki", "stucki_div"}
    assert set(pinned) == set(raw) - integers - {"about"}
    for key, digest in pinned.items():
        assert _digest(parsed[key]) == digest, key
    assert parsed["decode"] == parsed["decode_hex"] and parsed["pal_lin"] == parsed["pal_lin_hex"]
    assert parsed["decode"][128] == 0.21613417486051276  # shared/DITHER.md §3
    assert parsed["pal_lin"][1] == [1.0, 1.0, 1.0]
    assert {k: raw[k] for k in integers} == {
        "palette_srgb": [[76, 63, 89], [255, 255, 255], [73, 151, 107], [87, 97, 161], [216, 95, 99],
                         [254, 237, 116], [236, 126, 103]],
        "sectors": [[3, 4], [4, 6], [6, 5], [5, 2], [2, 3]],
        "stucki": [[8, 1, 0], [4, 2, 0], [2, -2, 1], [4, -1, 1], [8, 0, 1], [4, 1, 1], [2, 2, 1],
                   [1, -2, 2], [2, -1, 2], [4, 0, 2], [2, 1, 2], [1, 2, 2]],
        "stucki_div": 42,
    }


def test_strengths_are_the_grain_levels():
    assert VECTORS["strengths"] == list(image.GRAIN.values())


@pytest.mark.parametrize("case", VECTORS["colours"], ids=lambda c: c["name"])
def test_step_a_colours(case):
    *target, k = image._natural_step_a()(*bytes.fromhex(case["rgb"]))
    assert ([v.hex() for v in target], k) == (case["target"], case["set"])


@pytest.mark.parametrize("case", VECTORS["images"], ids=lambda c: c["name"])
def test_images(case):
    img = _image(case)
    for result in case["results"]:
        indices = image.natural(img, result["strength"])
        assert indices.hex()[1::2] == result["indices"], result["strength"]


@pytest.mark.parametrize("strength", VECTORS["strengths"])
@pytest.mark.parametrize("case", VECTORS["frames"], ids=lambda c: c["name"])
def test_frames(case, strength):
    rgb = zlib.decompress(base64.b64decode(case["rgb_deflate"]), wbits=-15)
    img = Image.frombytes("RGB", (case["width"], case["height"]), rgb)
    expected = next(r["sha256"] for r in case["results"] if r["strength"] == strength)
    assert hashlib.sha256(image.natural(img, strength)).hexdigest() == expected


def _noise(width, height, seed=3) -> Image.Image:
    rnd = random.Random(seed)
    img = Image.new("RGB", (width, height))
    img.putdata([tuple(rnd.randrange(256) for _ in range(3)) for _ in range(width * height)])
    return img


@pytest.mark.parametrize("size", [(37, 23), (1, 5), (5, 1), (2, 2)])
def test_natural_works_at_any_size_and_is_deterministic(size):
    img = _noise(*size)
    first = image.natural(img)
    assert len(first) == size[0] * size[1] and set(first) <= set(range(7))
    assert image.natural(img.copy()) == first
    assert image.natural(img.convert("RGBA")) == first  # any mode, read as RGB


def test_each_pixel_uses_black_white_and_the_inks_either_side_of_its_hue():
    img = _noise(40, 30)
    sectors = image.natural_tables()["sectors"]
    step_a = image._natural_step_a()
    raw = img.tobytes()
    for rgb, index in zip(zip(raw[0::3], raw[1::3], raw[2::3]), image.natural(img)):
        k = step_a(*rgb)[3]
        assert index in ((0, 1) if k < 0 else (0, 1, *sectors[k])), rgb


def test_greys_use_only_black_and_white():
    ramp = Image.new("RGB", (256, 4))
    ramp.putdata([(v, v, v) for _ in range(4) for v in range(256)])
    assert set(image.natural(ramp)) == {0, 1}
