"""Write shared/vectors/natural-vectors.json: the bytes every app's Natural and Bright
dithering must give (shared/DITHER.md §6).

    python python/tools/natural_vectors.py      (from the repository root, with python/src on PYTHONPATH)

The expected values come from ulani_epaper.image.natural() and bright(), the Python
reference.
Step A is worked out a second time here (probe()), only to find the edge cases:
colours near DEAD, KNEE and the hull boundary, next to each sector edge, and where
the cusp move's caps on c and e begin, plus skies, pastels and near-white tints the
cusp move changes a lot, a little or not at all. Four of step A's guards are never
reached by any 8-bit colour with the datasheet palette (checked over the whole cube):
u stays within 0-1, s is never <= 0, every colour that is not grey finds its sector,
and the cusp move's anchor always finds the hull boundary (its s is never <= 0 or
+inf). A colour the cusp move moves also stays outside the hull from its anchor
(ratio > 1), so the soft knee always applies to it.

Every input is generated here, nothing is a photo: a hue-tone plane, the gradient
card and the pastel picture the dithering research was judged on, and small pictures
cut from them. The output depends only on Python and Pillow (the pastel picture is
drawn, blurred and shrunk by Pillow; the committed file was made with Pillow 12.3).
Takes under a minute.
"""

from __future__ import annotations

import base64
import colorsys
import hashlib
import json
import math
import os
import random
import struct
import sys
import zlib

from PIL import Image, ImageDraw, ImageFilter

from ulani_epaper import image

W, H = 800, 480
STRENGTHS = [1.0, 0.8, 0.65, 0.5]
INTEGER_KEYS = ("palette_srgb", "sectors", "stucki", "stucki_div")
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
TABLES = os.path.join(ROOT, "shared", "dither", "natural-tables.json")
OUT = os.path.join(ROOT, "shared", "vectors", "natural-vectors.json")
DESCRIPTION = (
    "Natural and Bright dithering (shared/DITHER.md). Made by python/tools/natural_vectors.py: from the repository "
    "root, PYTHONPATH=python/src python python/tools/natural_vectors.py. "
    "tables_sha256: per key of shared/dither/natural-tables.json, the SHA-256 of its values as little-endian "
    "binary64 in JSON order (nested lists row by row); the integer keys palette_srgb, sectors, stucki and "
    "stucki_div are checked directly. colours: step A of one colour; rgb is hex, target three hex floats, set -1 "
    "for grey (candidates black and white) or the sector 0-4; they cover greys, the panel and ideal inks, the "
    "DEAD, KNEE and hull-boundary edges, both sides of each sector edge, and the cusp move (skies, pastels, "
    "near-white tints, colours just outside the hull, and both sides of its caps on c and e); bright_target and "
    "bright_set are the same colour under Bright, which has no cusp move. "
    "images: rgb is hex, three bytes per pixel, row-major; "
    "indices one hex digit per pixel, row-major. frames: rgb_deflate is base64 of the raw DEFLATE (no zlib header) "
    "of the width x height x 3 RGB bytes; sha256 is of the width x height indices, one byte each. In images and "
    "frames, results holds Natural's output at each strength and bright holds Bright's, which is what version 1 "
    "pinned for Natural.")


def flat(v):
    if isinstance(v, list):
        for x in v:
            yield from flat(x)
    else:
        yield v


def tables_sha256(tables: dict) -> dict:
    out = {}
    for key, value in tables.items():
        if key == "about" or key in INTEGER_KEYS:
            continue
        values = list(flat(value))
        assert all(isinstance(v, str) for v in values), key
        parse = float.fromhex if key.endswith("_hex") else float
        out[key] = hashlib.sha256(b"".join(struct.pack("<d", parse(v)) for v in values)).hexdigest()
    return out


# ---- inputs

def card() -> Image.Image:
    """The research's gradient card: six 80-pixel bands of left-to-right ramps: light sky,
    skin to coat, grey, a pastel hue circle (OKLab L 0.80, C 0.07), lavender, and a vivid
    hue circle (OKLab L 0.65, C 0.15, clipped to sRGB)."""
    def ramp(a, b):
        return [tuple((1 - t) * a[c] + t * b[c] for c in range(3)) for t in (i * (1 / (W - 1)) for i in range(W))]

    m2 = ((1.0, 0.3963377774, 0.2158037573), (1.0, -0.1055613458, -0.0638541728),
          (1.0, -0.0894841775, -1.2914855480))
    m1 = ((4.0767416621, -3.3077115913, 0.2309699292), (-1.2684380046, 2.6097574011, -0.3413193965),
          (-0.0041960863, -0.7034186147, 1.7076147010))

    def hue_circle(lightness, chroma):
        out = []
        for i in range(W):
            h = i * (2 * math.pi / W)
            lab = (lightness, chroma * math.cos(h), chroma * math.sin(h))
            lms = [(lab[0] * m[0] + lab[1] * m[1] + lab[2] * m[2]) ** 3 for m in m2]
            lin = [min(1.0, max(0.0, lms[0] * m[0] + lms[1] * m[1] + lms[2] * m[2])) for m in m1]
            out.append(tuple(255 * (12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055) for v in lin))
        return out

    bands = [ramp((120, 160, 225), (250, 250, 255)), ramp((255, 240, 230), (200, 130, 105)),
             ramp((0, 0, 0), (255, 255, 255)), hue_circle(0.80, 0.07), ramp((150, 120, 200), (240, 235, 250)),
             hue_circle(0.65, 0.15)]
    img = Image.new("RGB", (W, H))
    img.putdata([px for band in bands for px in [tuple(round(v) for v in p) for p in band] * (H // len(bands))])
    return img


def pastel() -> Image.Image:
    """The research's pastel picture (light sky, clouds, lavender hair, light skin, a peach
    coat, a white collar and a red ribbon), drawn at 1600x960 and shrunk to the panel."""
    w, h = 2 * W, 2 * H
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / h
        c = (int(120 + 90 * t), int(160 + 70 * t), int(225 + 25 * t))
        for x in range(w):
            px[x, y] = c
    draw = ImageDraw.Draw(img)
    rnd = random.Random(7)
    for _ in range(14):
        x, y = rnd.randint(0, w), rnd.randint(int(h * .2), h)
        r = rnd.randint(60, 160)
        draw.ellipse((x - r * 2, y - r, x + r * 2, y + r), fill=(238, 242, 250))
    img = img.filter(ImageFilter.GaussianBlur(18))
    draw = ImageDraw.Draw(img)
    draw.ellipse((600, 180, 1000, 640), fill=(176, 150, 210))
    draw.ellipse((680, 250, 920, 560), fill=(252, 228, 214))
    draw.polygon([(520, 960), (640, 600), (960, 600), (1080, 960)], fill=(200, 130, 105))
    draw.rectangle((760, 600, 840, 700), fill=(250, 246, 240))
    draw.polygon([(790, 640), (810, 640), (820, 760), (780, 760)], fill=(205, 70, 90))
    img = img.filter(ImageFilter.GaussianBlur(3))
    return img.resize((W, H), Image.LANCZOS)


def hue_tone(width: int, height: int, block: int = 1) -> Image.Image:
    """Hue round the circle from left to right; from top to bottom, three bands: black to
    full colour, full colour to white, full colour to a mid grey. In ``block``-pixel squares."""
    bw, bh = width // block, height // block
    band = bh // 3
    img = Image.new("RGB", (width, height))
    data = []
    for by in range(bh):
        part, k = divmod(min(by, 3 * band - 1), band)
        f = k / (band - 1)
        s, v = ((1.0, f), (1.0 - f, 1.0), (1.0 - f, 0.6))[part]
        row = [tuple(round(c * 255) for c in colorsys.hsv_to_rgb(bx / bw, s, v)) for bx in range(bw)]
        data += [px for px in row for _ in range(block)] * block
    img.putdata(data)
    return img


def sky_gradient(width: int, height: int) -> Image.Image:
    """A sky: from a bright sky blue at the top to white at the bottom, a little paler to the right."""
    top, bottom = (110, 185, 245), (255, 255, 255)
    img = Image.new("RGB", (width, height))
    data = []
    for y in range(height):
        for x in range(width):
            f = min(1.0, (y + x / (2 * width)) / (height - 1))
            data.append(tuple(round(a + (b - a) * f) for a, b in zip(top, bottom)))
    img.putdata(data)
    return img


def flat_image(rgb, size=(8, 8)) -> Image.Image:
    return Image.new("RGB", size, tuple(rgb))


# ---- step A, again, with the values the edge cases are about

def _hull_s(t, g0, g1, g2, d0, d1, d2) -> float:
    s = math.inf
    for nx, ny, nz, dd in t["facets"]:
        nd = nx * d0 + ny * d1 + nz * d2
        if nd > 1e-12:
            v = (dd - (nx * g0 + ny * g1 + nz * g2)) / nd
            if v < s:
                s = v
    return s


def probe(rgb, cusp_move: bool = True) -> dict:
    """Step A as shared/DITHER.md §4 writes it, also returning u before the clamp, ratio
    and r1 before the knee at the colour's own lightness (before the cusp move), the
    hue-plane position (x, y) and, for a colour the cusp move applies to, c and e before
    their caps, the anchor's lightness ua and the anchor's s. Without ``cusp_move``: Bright."""
    t = image.natural_tables()
    dec, (l0, l1, l2) = t["decode"], t["luma"]
    (k0, k1, k2), (w0, w1, w2) = t["k"], t["wk"]
    r, g, b = (dec[c] for c in rgb)
    y = l0 * r + l1 * g + l2 * b
    r = y + t["sat"] * (r - y); g = y + t["sat"] * (g - y); b = y + t["sat"] * (b - y)
    r = k0 + w0 * r; g = k1 + w1 * g; b = k2 + w2 * b
    u_raw = (l0 * r + l1 * g + l2 * b - t["yk"]) / t["yrange"]
    u = 0 if u_raw < 0 else (1 if u_raw > 1 else u_raw)
    g0 = k0 + w0 * u; g1 = k1 + w1 * u; g2 = k2 + w2 * u
    d0 = r - g0; d1 = g - g1; d2 = b - g2
    s = _hull_s(t, g0, g1, g2, d0, d1, d2)
    ratio = 0 if s == math.inf else (math.inf if s <= 0 else 1 / s)
    dead, knee = t["dead"], t["knee"]
    out = {"u": u_raw, "ratio": ratio, "r1": None, "x": None, "y": None, "c": None, "e": None, "ua": None,
           "anchor_s": None}
    if ratio <= dead or ratio == math.inf:
        return {**out, "target": (g0, g1, g2), "set": -1}
    out["r1"] = (ratio - dead) / (1 - dead)
    (a0, a1, a2), (b0, b1, b2) = t["e1"], t["e2"]
    x = a0 * d0 + a1 * d1 + a2 * d2
    y = b0 * d0 + b1 * d1 + b2 * d2
    out["x"], out["y"] = x, y
    k = next((k for k, (ax, ay, bx, by) in enumerate(t["sector_xy"]) if ax * y - ay * x >= 0 and x * by - y * bx > 0),
             None)
    if cusp_move and ratio > 1 and k is not None:  # the cusp move
        (ax, ay, bx, by), (i, j), ink_u = t["sector_xy"][k], t["sectors"][k], t["ink_u"]
        p = ax * y - ay * x
        q = x * by - y * bx
        tt = p / (p + q)
        uc = ink_u[i] + tt * (ink_u[j] - ink_u[i])
        cx = ax + tt * (bx - ax); cy = ay + tt * (by - ay)
        c = out["c"] = (x * cx + y * cy) / (cx * cx + cy * cy) / t["cusp_ref"]
        if c > 1:
            c = 1.0
        e = out["e"] = (ratio - 1) / t["cusp_span"]
        if e > 1:
            e = 1.0
        w = t["cusp"] * c * c * e
        ua = out["ua"] = u + w * (uc - u)
        h0 = k0 + w0 * ua; h1 = k1 + w1 * ua; h2 = k2 + w2 * ua
        m0 = r - h0; m1 = g - h1; m2 = b - h2
        s = out["anchor_s"] = _hull_s(t, h0, h1, h2, m0, m1, m2)
        if s > 0 and s != math.inf:
            g0, g1, g2, d0, d1, d2 = h0, h1, h2, m0, m1, m2
            ratio = 1 / s
    r1 = (ratio - dead) / (1 - dead)
    if r1 > knee:
        x = (r1 - knee) / (1 - knee)
        r1 = knee + (1 - knee) * x / (1 + x)
    f = r1 / ratio
    return {**out, "target": (g0 + f * d0, g1 + f * d1, g2 + f * d2), "set": 0 if k is None else k}


def closest(probes: dict, key, side: str, lo=None) -> tuple:
    """The colour whose key(probe) is smallest above 0 (side "above") or largest at or below 0."""
    best, best_v = None, None
    for rgb, p in probes.items():
        v = key(p)
        if v is None or (lo is not None and not lo(p)):
            continue
        if side == "above" and v > 0 and (best_v is None or v < best_v) or \
                side == "below" and v <= 0 and (best_v is None or v > best_v):
            best, best_v = rgb, v
    return best


def refine(rgb, key, side: str, lo=None) -> tuple:
    """closest() again among the colours within 4 levels of ``rgb``."""
    near = {}
    for dr in range(-4, 5):
        for dg in range(-4, 5):
            for db in range(-4, 5):
                c = (rgb[0] + dr, rgb[1] + dg, rgb[2] + db)
                if all(0 <= v <= 255 for v in c):
                    near[c] = probe(c)
    return closest(near, key, side, lo)


def edge_cases() -> list[tuple[str, tuple]]:
    t = image.natural_tables()
    grid = range(0, 256, 5)
    probes = {(r, g, b): probe((r, g, b)) for r in grid for g in grid for b in grid}
    cases = []
    dead, knee = t["dead"], t["knee"]
    keys = (("DEAD", lambda p: None if p["ratio"] == math.inf else p["ratio"] - dead),
            ("KNEE", lambda p: None if p["r1"] is None else p["r1"] - knee),
            ("ratio 1 (the hull boundary)", lambda p: None if p["ratio"] == math.inf else p["ratio"] - 1))
    for lo_name, lo in (("dark", lambda p: p["u"] < 0.5), ("light", lambda p: p["u"] >= 0.5)):
        for side in ("below", "above"):
            for name, key in keys:
                rgb = refine(closest(probes, key, side, lo), key, side, lo)
                cases.append((f"{lo_name}, just {side} {name}", rgb))
    sector_names = {2: "green", 3: "blue", 4: "red", 5: "yellow", 6: "orange"}
    for k, (ink, (ax, ay, _, _)) in enumerate(zip((a for a, _ in t["sectors"]), t["sector_xy"])):
        def short(p, ax=ax, ay=ay):  # how far short of the ink's direction; None behind the axis
            if p["x"] is None or ax * p["x"] + ay * p["y"] <= 0:
                return None
            return -(ax * p["y"] - ay * p["x"])

        for side in ("below", "above"):  # sector k takes ax*y - ay*x >= 0, i.e. short <= 0
            rgb = refine(closest(probes, short, side), short, side)
            where = "on or just past" if side == "below" else "just before"
            cases.append((f"{where} the {sector_names[ink]} edge (sector {k} starts there)", rgb))
    return cases


#: Colours the cusp move changes a lot (skies, pastels) or a little (a near-white tint, warm
#: tones just outside the hull); the colours above that lie inside the hull it does not change.
CUSP_COLOURS = [
    ("cusp move: bright sky blue", (118, 209, 251)), ("cusp move: sky blue", (114, 197, 241)),
    ("cusp move: pale sky blue", (180, 233, 251)), ("cusp move: very pale sky blue", (192, 245, 255)),
    ("cusp move: near-white blue tint", (230, 245, 255)), ("cusp move: pink", (255, 182, 203)),
    ("cusp move: pale pink", (250, 210, 220)), ("cusp move: mint", (170, 240, 200)),
    ("cusp move: lavender", (200, 180, 240)), ("cusp move: pale yellow", (255, 245, 160)),
    ("cusp move: peach", (255, 205, 170)), ("cusp move: light skin", (240, 200, 175)),
    ("cusp move: mid sky blue", (110, 170, 225)), ("cusp move: dusky blue", (80, 110, 160)),
]


def cusp_edge_cases() -> list[tuple[str, tuple]]:
    """Colours next to where the cusp move's caps begin (c and e reaching 1), and the
    largest changes of lightness just outside the hull and on the whole grid."""
    grid = range(0, 256, 5)
    probes = {(r, g, b): probe((r, g, b)) for r in grid for g in grid for b in grid}
    cases = []

    def c_cap(p):
        return None if p["c"] is None else p["c"] - 1

    def e_cap(p):
        return None if p["e"] is None else p["e"] - 1

    def shift(p):  # how far the cusp move moves the anchor's lightness
        return abs(p["ua"] - max(0.0, min(1.0, p["u"])))

    for lo_name, lo in (("dark", lambda p: p["u"] < 0.5), ("light", lambda p: p["u"] >= 0.5)):
        for side in ("below", "above"):
            rgb = refine(closest(probes, c_cap, side, lo), c_cap, side, lo)
            cases.append((f"cusp move: {lo_name}, c just {side} its cap", rgb))
    for side in ("below", "above"):
        rgb = refine(closest(probes, e_cap, side), e_cap, side)
        cases.append((f"cusp move: e just {side} its cap (ratio near 1 + SPAN)", rgb))
    moved = [(shift(p), p["ratio"], rgb) for rgb, p in probes.items() if p["ua"] is not None]
    near = max(m for m in moved if m[1] <= 1.05)[2]
    cases.append(("cusp move: the largest change of lightness just outside the hull (ratio up to 1.05)", near))
    cases.append(("cusp move: the largest change of lightness on the grid", max(moved)[2]))
    for name, rgb in cases:
        s = probe(rgb)["anchor_s"]
        assert s is not None and 0 < s < math.inf, (name, rgb)
    return cases


def colour_cases() -> list[dict]:
    t = image.natural_tables()
    named = [(f"grey {v}", (v, v, v)) for v in (0, 1, 2, 127, 128, 254, 255)]
    names = ("black", "white", "green", "blue", "red", "yellow", "orange")
    named += [(f"panel {n}", tuple(rgb)) for n, rgb in zip(names, t["palette_srgb"])]
    named += [(f"ideal {c.name}", c.rgb) for c in image.PALETTE]
    named += [
        ("sky, top of the pastel picture", (120, 160, 225)), ("sky, bottom of the pastel picture", (209, 229, 249)),
        ("cloud", (238, 242, 250)), ("lavender hair", (176, 150, 210)), ("light skin", (252, 228, 214)),
        ("peach coat", (200, 130, 105)), ("white collar", (250, 246, 240)), ("red ribbon", (205, 70, 90)),
        ("light sky ramp end", (250, 250, 255)), ("skin ramp start", (255, 240, 230)),
        ("lavender ramp start", (150, 120, 200)), ("lavender ramp end", (240, 235, 250)),
        ("dull mid-tone", (128, 110, 100)), ("dark olive", (60, 64, 30)), ("deep purple", (60, 20, 90)),
        ("teal", (0, 128, 128)), ("magenta", (255, 0, 255)), ("cyan", (0, 255, 255)),
    ]
    named += edge_cases()
    named += CUSP_COLOURS + cusp_edge_cases()
    step_a, bright_a = image._natural_step_a(), image._natural_step_a(False)
    out, seen = [], set()
    for name, rgb in named:
        if rgb in seen:
            continue
        seen.add(rgb)
        *target, k = step_a(*rgb)
        *bright_target, bright_k = bright_a(*rgb)
        p, b = probe(rgb), probe(rgb, cusp_move=False)
        assert (tuple(target), k) == (p["target"], p["set"]), (name, rgb)
        assert (tuple(bright_target), bright_k) == (b["target"], b["set"]), (name, rgb)
        out.append({"name": name, "rgb": bytes(rgb).hex(), "target": [v.hex() for v in target], "set": k,
                    "bright_target": [v.hex() for v in bright_target], "bright_set": bright_k})
    return out


def image_case(name: str, img: Image.Image) -> dict:
    def results(method):
        return [{"strength": s, "indices": "".join("0123456"[i] for i in method(img, s))} for s in STRENGTHS]

    return {"name": name, "width": img.width, "height": img.height, "rgb": img.tobytes().hex(),
            "results": results(image.natural), "bright": results(image.bright)}


def image_cases(frames: dict, colours: list[dict]) -> list[dict]:
    cases = [image_case(f"1x1 grey {v}", flat_image((v, v, v), (1, 1))) for v in (0, 1, 2, 127, 128, 254, 255)]
    by_name = {c["name"]: tuple(bytes.fromhex(c["rgb"])) for c in colours}
    for name, rgb in by_name.items():
        if name.startswith(("dark, just", "light, just", "on or just past", "just before")):
            cases.append(image_case(f"8x8 of {name}", flat_image(rgb)))
    rnd = random.Random(1)
    noise = Image.new("RGB", (8, 8))
    noise.putdata([tuple(rnd.randrange(256) for _ in range(3)) for _ in range(64)])
    cases.append(image_case("8x8 random colours", noise))
    edges = Image.new("RGB", (8, 8))
    pairs = [(by_name[f"just before the {n} edge (sector {k} starts there)"],
              by_name[f"on or just past the {n} edge (sector {k} starts there)"])
             for k, n in enumerate(("blue", "red", "orange", "yellow", "green"))]
    edges.putdata([pairs[y % 5][(x + y) % 2] for y in range(8) for x in range(8)])
    cases.append(image_case("8x8 checker of the two sides of each sector edge", edges))
    cases.append(image_case("1x8 column of the hue-tone plane", hue_tone(16, 8).crop((5, 0, 6, 8))))
    cases.append(image_case("8x1 row of the hue-tone plane", hue_tone(8, 24).crop((0, 10, 8, 11))))
    cases.append(image_case("3x2 panel colours", Image.frombytes(
        "RGB", (3, 2), bytes(v for rgb in image.natural_tables()["palette_srgb"][1:] for v in rgb))))
    cases.append(image_case("7x3 ideal colours, one column each", Image.frombytes(
        "RGB", (7, 3), bytes(v for _ in range(3) for c in image.PALETTE for v in c.rgb))))
    cases.append(image_case("48x24 hue-tone plane", hue_tone(48, 24)))
    for name in ("pastel", "card"):
        for size in ((32, 20), (64, 40)):
            cases.append(image_case(f"{name} picture shrunk to {size[0]}x{size[1]}",
                                    frames[name].resize(size, Image.LANCZOS)))
    cases.append(image_case("pastel picture, 64x40 crop at the ribbon", frames["pastel"].crop((368, 300, 432, 340))))
    cases.append(image_case("card, 64x40 crop across bands 1 to 2", frames["card"].crop((300, 140, 364, 180))))
    cases.append(image_case("24x16 sky gradient, sky blue at the top to white at the bottom", sky_gradient(24, 16)))
    return cases


def frame_case(name: str, img: Image.Image) -> dict:
    deflate = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = deflate.compress(img.tobytes()) + deflate.flush()

    def results(method):
        return [{"strength": s, "sha256": hashlib.sha256(method(img, s)).hexdigest()} for s in STRENGTHS]

    return {"name": name, "width": img.width, "height": img.height,
            "rgb_deflate": base64.b64encode(packed).decode("ascii"),
            "results": results(image.natural), "bright": results(image.bright)}


def build() -> dict:
    with open(TABLES, encoding="utf-8") as f:
        tables = json.load(f)
    frames = {"hue-tone": hue_tone(W, H, 4), "card": card(), "pastel": pastel()}
    colours = colour_cases()
    return {
        "version": 3,
        "description": DESCRIPTION,
        "tables_sha256": tables_sha256(tables),
        "strengths": STRENGTHS,
        "colours": colours,
        "images": image_cases(frames, colours),
        "frames": [frame_case("hue-tone plane in 4-pixel squares", frames["hue-tone"]),
                   frame_case("gradient card", frames["card"]),
                   frame_case("pastel picture", frames["pastel"])],
    }


def dumps(doc: dict) -> str:
    """JSON with one colour, field or result per line."""
    def inline(v):
        return json.dumps(v, ensure_ascii=False)

    def block(items, indent, render):
        pad = " " * indent
        return "[\n" + ",\n".join(pad + render(item) for item in items) + "\n" + pad[:-1] + "]"

    def case(item):
        fields = [f'   {inline(k)}: {block(v, 4, inline) if k in ("results", "bright") else inline(v)}'
                  for k, v in item.items()]
        return "{\n" + ",\n".join(fields) + "\n  }"

    lines = []
    for key, value in doc.items():
        if key == "tables_sha256":
            body = "{\n" + ",\n".join(f"  {inline(k)}: {inline(v)}" for k, v in value.items()) + "\n }"
        elif key == "colours":
            body = block(value, 2, inline)
        elif key in ("images", "frames"):
            body = block(value, 2, case)
        else:
            body = inline(value)
        lines.append(f" {inline(key)}: {body}")
    text = "{\n" + ",\n".join(lines) + "\n}\n"
    assert json.loads(text) == doc
    return text


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(build()))
    print(f"wrote {out} ({os.path.getsize(out):,} bytes)")


if __name__ == "__main__":
    main()
