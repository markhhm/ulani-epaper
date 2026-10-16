"""Natural and Bright dithering against shared/vectors/natural-vectors.json (shared/DITHER.md §6).

The vectors are made by python/tools/natural_vectors.py; from the repository root:

    PYTHONPATH=python/src python python/tools/natural_vectors.py

and the tables by python/tools/natural_tables.py (needs numpy).
"""

import base64
import hashlib
import itertools
import json
import math
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


def test_the_vectors_pin_natural_and_bright():
    assert VECTORS["version"] == 3
    assert all({"bright_target", "bright_set"} <= set(case) for case in VECTORS["colours"])
    for case in VECTORS["images"] + VECTORS["frames"]:
        assert [r["strength"] for r in case["bright"]] == [r["strength"] for r in case["results"]] == VECTORS[
            "strengths"], case["name"]


@pytest.mark.parametrize("case", VECTORS["colours"], ids=lambda c: c["name"])
def test_step_a_colours(case):
    rgb = bytes.fromhex(case["rgb"])
    *target, k = image._natural_step_a()(*rgb)
    assert ([v.hex() for v in target], k) == (case["target"], case["set"])
    *target, k = image._natural_step_a(False)(*rgb)  # 明亮 / Bright
    assert ([v.hex() for v in target], k) == (case["bright_target"], case["bright_set"])


@pytest.mark.parametrize("case", VECTORS["images"], ids=lambda c: c["name"])
def test_images(case):
    img = _image(case)
    for key, method in (("results", image.natural), ("bright", image.bright)):
        for result in case[key]:
            indices = method(img, result["strength"])
            assert indices.hex()[1::2] == result["indices"], (key, result["strength"])


def _frame(case) -> Image.Image:
    rgb = zlib.decompress(base64.b64decode(case["rgb_deflate"]), wbits=-15)
    return Image.frombytes("RGB", (case["width"], case["height"]), rgb)


@pytest.mark.parametrize("strength", VECTORS["strengths"])
@pytest.mark.parametrize("case", VECTORS["frames"], ids=lambda c: c["name"])
def test_frames(case, strength):
    img = _frame(case)
    for key, method in (("results", image.natural), ("bright", image.bright)):
        expected = next(r["sha256"] for r in case[key] if r["strength"] == strength)
        assert hashlib.sha256(method(img, strength)).hexdigest() == expected, key


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


# ---- the cusp move (shared/DITHER.md §4, Paperhue 0.4.2)

#: Step-A cases of shared/vectors/natural-vectors.json version 1 (Paperhue 0.4.0 and 0.4.1, before the
#: cusp move), all colours that version 2 changes: (rgb, target as hex floats, set).
PLAIN_0_4_0 = [
    ("49976b", ("0x1.3e3ef9c6d1423p-3", "0x1.6419086ba6c6ep-2", "0x1.f161f07e21966p-3"), 4),  # panel green
    ("5761a1", ("0x1.4945a6586a927p-3", "0x1.412063a25b8fbp-3", "0x1.78fca3c1cbe38p-2"), 0),  # panel blue
    ("ff0000", ("0x1.3515371d93b5dp-1", "0x1.3fa90e5d051e4p-3", "0x1.9af2702c58c60p-3"), 0),  # ideal red
    ("ffff00", ("0x1.e2d83f6261493p-1", "0x1.e222b49c9f62dp-1", "0x1.b73f1141db4b8p-1"), 3),  # ideal yellow
    ("ff7d00", ("0x1.ad4d1c8617c59p-1", "0x1.20af1f0211e90p-2", "0x1.7cb8e898e2865p-3"), 2),  # ideal orange
    ("78a0e1", ("0x1.75654b7d556f1p-2", "0x1.973ed99344f81p-2", "0x1.109f09c20b7d4p-1"), 4),  # sky, pastel top
    ("d1e5f9", ("0x1.9b450b08014c5p-1", "0x1.a3f30bc7bb2aap-1", "0x1.b301863b0d55fp-1"), 4),  # sky, pastel bottom
    ("eef2fa", ("0x1.d3c85fd44a704p-1", "0x1.d6558a8128a5fp-1", "0x1.df3d96143ac62p-1"), 4),  # cloud
    ("b096d2", ("0x1.ca296562be862p-2", "0x1.905a04a20c843p-2", "0x1.0d1e238768410p-1"), 0),  # lavender hair
    ("fce4d6", ("0x1.ecf33bffcb0f5p-1", "0x1.aab0831595e5cp-1", "0x1.89683e673dd22p-1"), 2),  # light skin
    ("cd465a", ("0x1.0eef83631e3ebp-1", "0x1.1e80a22e64d87p-3", "0x1.ac4bc1fedbe61p-3"), 0),  # red ribbon
    ("3c145a", ("0x1.806fd7cc70856p-4", "0x1.fb33f9fcf749ep-5", "0x1.1a82a05689229p-3"), 0),  # deep purple
    ("008080", ("0x1.eebffb7a2189cp-4", "0x1.effd95af527d9p-3", "0x1.20fb60a5ea3dap-2"), 4),  # teal
    ("00ffff", ("0x1.8e58fd7a1e602p-1", "0x1.9e8cfbfbdc65cp-1", "0x1.a3b29fd43616bp-1"), 4),  # cyan
    ("3c2332", ("0x1.b92e81ce19b52p-4", "0x1.ec00119861779p-5", "0x1.f4ca11e332a98p-4"), 0),  # dark, just outside
    ("d9b573", ("0x1.97d213bb97254p-1", "0x1.0abe8658ed601p-1", "0x1.8c6194b500918p-3"), 2),  # light, just outside
    ("f04b05", ("0x1.618db8f1ecceap-1", "0x1.4c3690f9fb308p-3", "0x1.620066407a8cfp-3"), 1),  # red edge
    ("2dbe69", ("0x1.4a5f2195c26aep-2", "0x1.fcb9a06f7fb78p-2", "0x1.85b35f3fee97ap-2"), 3),  # green edge
]
#: Version 1's "8x8 random colours" (the noise of seed 1) at strength 1.
PLAIN_0_4_0_NOISE = "0151262033433322533331440112151610204223011320130561200303021312"


@pytest.fixture
def steps(monkeypatch):
    """Step A as shipped, and with CUSP 0 (the plain mapping); natural() uses the plain one while the test runs."""
    image._natural_step_a.cache_clear()
    moved = image._natural_step_a()
    image._natural_step_a.cache_clear()
    monkeypatch.setitem(image.natural_tables(), "cusp", 0.0)
    yield moved, image._natural_step_a()
    monkeypatch.undo()
    image._natural_step_a.cache_clear()


def _bpc(rgb):
    """r, g, b of step A after the saturation boost and the black-point compensation."""
    t = image.natural_tables()
    r, g, b = (t["decode"][v] for v in rgb)
    l0, l1, l2 = t["luma"]
    y = l0 * r + l1 * g + l2 * b
    return [k + w * (y + t["sat"] * (v - y)) for k, w, v in zip(t["k"], t["wk"], (r, g, b))]


def _outside(rgb) -> float:
    """How far the colour lies outside the panel's colours (the hull), in linear light; < 0 inside."""
    p = _bpc(rgb)
    return max(nx * p[0] + ny * p[1] + nz * p[2] - d for nx, ny, nz, d in image.natural_tables()["facets"])


def _lightness(target) -> float:
    """u of a target: its place on the panel's grey scale."""
    t = image.natural_tables()
    l0, l1, l2 = t["luma"]
    return (l0 * target[0] + l1 * target[1] + l2 * target[2] - t["yk"]) / t["yrange"]


def _colourfulness(target) -> float:
    """How far a target lies from the panel grey of its own lightness, across the grey axis."""
    t = image.natural_tables()
    u = _lightness(target)
    d = [target[i] - (t["k"][i] + t["wk"][i] * u) for i in range(3)]
    return math.hypot(sum(a * v for a, v in zip(t["e1"], d)), sum(b * v for b, v in zip(t["e2"], d)))


def test_the_tables_carry_the_cusp_move():
    t = image.natural_tables()
    assert (t["cusp"], t["cusp_span"], t["cusp_ref"]) == (0.9, 2.0, 3.0)
    l0, l1, l2 = t["luma"]
    assert t["ink_u"] == [(l0 * p[0] + l1 * p[1] + l2 * p[2] - t["yk"]) / t["yrange"] for p in t["pal_lin"]]
    assert t["ink_u"][:2] == [0.0, 1.0]


def test_without_the_cusp_move_step_a_is_the_plain_mapping_of_0_4_0(steps):
    moved, plain = steps
    for rgb, target, k in PLAIN_0_4_0:
        *got, got_k = plain(*bytes.fromhex(rgb))
        assert (tuple(v.hex() for v in got), got_k) == (target, k), rgb
        *got, got_k = moved(*bytes.fromhex(rgb))
        assert tuple(v.hex() for v in got) != target and got_k == k, rgb  # the move never changes the set
    assert image.natural(_noise(8, 8, seed=1)).hex()[1::2] == PLAIN_0_4_0_NOISE


def test_the_cusp_move_changes_whole_pictures():
    assert image.natural(_noise(8, 8, seed=1)).hex()[1::2] != PLAIN_0_4_0_NOISE


# ---- 明亮 / Bright: Natural without the cusp move, exactly the Natural of 0.4.0 and 0.4.1

#: Version 1's frames (the same inputs as now) at strength 1: the SHA-256 of Natural's indices then.
PLAIN_0_4_0_FRAMES = {
    "hue-tone plane in 4-pixel squares": "c1f1f7566ff08617ceff5c00de1ef498b20b26f41c69364e4f9d47fc52d22be4",
    "gradient card": "4759227df6a094ba2a7577f1803545a2a169d63a728a0f9e6a4f2508e0aa56ad",
    "pastel picture": "eb97e660a5f4d1907acd221f22b02710bacb1000a874e1e560feeebb3db465d3",
}


def test_bright_step_a_is_the_plain_mapping_of_0_4_0():
    bright = image._natural_step_a(False)
    for rgb, target, k in PLAIN_0_4_0:
        *got, got_k = bright(*bytes.fromhex(rgb))
        assert (tuple(v.hex() for v in got), got_k) == (target, k), rgb
    assert image.bright(_noise(8, 8, seed=1)).hex()[1::2] == PLAIN_0_4_0_NOISE


def test_bright_is_the_cusp_move_at_strength_0(steps):
    _, plain = steps
    bright = image._natural_step_a(False)
    for rgb in itertools.product(range(0, 256, 15), repeat=3):
        assert bright(*rgb) == plain(*rgb), rgb


@pytest.mark.parametrize("case", VECTORS["frames"], ids=lambda c: c["name"])
def test_bright_frames_are_the_natural_frames_of_0_4_0(case):
    assert hashlib.sha256(image.bright(_frame(case))).hexdigest() == PLAIN_0_4_0_FRAMES[case["name"]]


def test_colours_the_panel_can_show_are_untouched_by_the_cusp_move(steps):
    moved, plain = steps
    inside = changed = 0
    for rgb in itertools.product(range(0, 256, 15), repeat=3):
        out = _outside(rgb)
        same = moved(*rgb) == plain(*rgb)
        if out < -1e-9:  # inside the hull, with a margin for rounding at the boundary
            assert same, rgb
            inside += 1
        if not same:
            assert out > -1e-9, rgb
            changed += 1
    assert inside > 200 and changed > 3000


def test_a_vivid_sky_blue_comes_out_darker_and_more_colourful(steps):
    moved, plain = steps
    sky = (118, 209, 251)
    before, after = plain(*sky)[:3], moved(*sky)[:3]
    assert _lightness(after) < _lightness(before) - 0.3  # 0.60 -> 0.24
    assert _colourfulness(after) > 1.5 * _colourfulness(before)  # 0.057 -> 0.110


def test_a_near_white_tint_hardly_moves(steps):
    moved, plain = steps
    t = image.natural_tables()
    tint, sky = (230, 245, 255), (118, 209, 251)

    def drop(rgb):
        return _lightness(plain(*rgb)[:3]) - _lightness(moved(*rgb)[:3])

    def oklab_l(target):  # for a near-grey, OKLab L is about the cube root of the luminance
        return (t["yk"] + t["yrange"] * _lightness(target)) ** (1 / 3)

    assert 0 < drop(tint) < 0.1  # 0.080 in u
    assert drop(tint) < drop(sky) / 4  # the sky drops 0.365
    assert oklab_l(plain(*tint)[:3]) - oklab_l(moved(*tint)[:3]) < 0.05  # 0.028
