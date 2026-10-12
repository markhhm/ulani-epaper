"""Write shared/vectors/dither-vectors.json: expected palette indices for the
Stucki ditherer in web/src/core/dither.ts.

The expected values come from the integer procedure written out at the top of
dither.ts, implemented again here in plain Python (no packages needed, and
nothing from python/src), so the vectors never depend on the code they check.
From the repository root:

    python web/scripts/gen_dither_vectors.py [OUT]

OUT defaults to shared/vectors/dither-vectors.json next to web/. The file is
written as UTF-8 with LF line endings by this script (no shell redirection).

Layout (version 1):

- ``kernel`` / ``divisor``: the Stucki taps ``[weight, dx, dy]`` and their sum.
- ``keep_in_range``: ``{"in": [r, g, b], "out": [r, g, b]}`` for the range
  handling applied to every pixel that receives error.
- ``images``: small deterministic pictures. ``rgb`` is lower-case hex, three
  bytes per pixel, row-major from the top-left. Each entry of ``results`` gives
  the ``strength`` and the expected ``indices``, one hex digit per pixel in the
  same order. Most pictures use the ``strengths`` list; the two "factor
  order" pictures and the "nearest colour boundaries" picture use strengths
  of their own. ``lift`` / ``scale`` count how often the two range rules fired
  (information only: they show that the extremes are exercised).

Strength 0.0 spreads no error, so those results are also the plain nearest
colour of every pixel: the expected output without dithering. The nearest
colour is exact: full 8-bit channels, smallest squared distance, lowest index
on a tie. A search at reduced channel precision (some colour quantizers drop
the low 2 bits of each channel) disagrees for about 1 % of all colours; the
"nearest colour boundaries" picture pins such colours.
"""

from __future__ import annotations

import json
import os
import sys

STRENGTHS = (1.0, 0.8, 0.65, 0.5, 0.0)

#: The panel colours by index (src/core/palette.ts).
PALETTE = [
    (0, 0, 0),        # black
    (255, 255, 255),  # white
    (0, 255, 0),      # green
    (0, 0, 255),      # blue
    (255, 0, 0),      # red
    (255, 255, 0),    # yellow
    (255, 125, 0),    # orange
]

#: Stucki taps (weight, dx, dy) in raster order; the weights sum to DIVISOR.
KERNEL = (
    (8, 1, 0), (4, 2, 0),
    (2, -2, 1), (4, -1, 1), (8, 0, 1), (4, 1, 1), (2, 2, 1),
    (1, -2, 2), (2, -1, 2), (4, 0, 2), (2, 1, 2), (1, 2, 2),
)
DIVISOR = 42
assert sum(w for w, _, _ in KERNEL) == DIVISOR


def nearest(r: int, g: int, b: int) -> int:
    """Index of the closest palette colour: smallest squared RGB distance,
    lowest index on a tie."""
    best, best_distance = 0, None
    for k, (cr, cg, cb) in enumerate(PALETTE):
        d = (cr - r) ** 2 + (cg - g) ** 2 + (cb - b) ** 2
        if best_distance is None or d < best_distance:
            best, best_distance = k, d
    return best


class RangeStats:
    """How often each range rule fired."""

    def __init__(self) -> None:
        self.lift = 0
        self.scale = 0


def keep_in_range(r: int, g: int, b: int, stats: RangeStats | None = None) -> tuple[int, int, int]:
    """Lift (lowest channel below 0), then scale (highest above 255), then
    clamp, as specified in dither.ts."""
    low = min(r, g, b)
    if low < 0:
        if stats:
            stats.lift += 1
        lift = int(255 * -low / (255 - low))
        r, g, b = r + lift, g + lift, b + lift
    high = max(r, g, b)
    if high > 255:
        if stats:
            stats.scale += 1
        scale = 255 / high
        r, g, b = int(r * scale), int(g * scale), int(b * scale)
    return tuple(0 if c < 0 else 255 if c > 255 else c for c in (r, g, b))


def stucki(width: int, height: int, pixels: list[tuple[int, int, int]], strength: float,
           stats: RangeStats | None = None) -> list[int]:
    """Palette indices with Stucki error diffusion (raster order, error per
    channel spread with trunc(error * (w / 42 * strength)), every target
    passed through keep_in_range)."""
    r = [p[0] for p in pixels]
    g = [p[1] for p in pixels]
    b = [p[2] for p in pixels]
    taps = [(w / float(DIVISOR) * strength, dx, dy) for w, dx, dy in KERNEL]
    out = []
    for y in range(height):
        for x in range(width):
            i = y * width + x
            best = nearest(r[i], g[i], b[i])
            out.append(best)
            cr, cg, cb = PALETTE[best]
            er, eg, eb = r[i] - cr, g[i] - cg, b[i] - cb
            for f, dx, dy in taps:
                xx, yy = x + dx, y + dy
                if 0 <= xx < width and yy < height:
                    j = yy * width + xx
                    r[j], g[j], b[j] = keep_in_range(
                        r[j] + int(er * f), g[j] + int(eg * f), b[j] + int(eb * f), stats)
    return out


class Rng:
    """Small deterministic generator (xorshift32), so the pictures never
    depend on the Python version. Only this script uses it: the pictures are
    stored as pixels, not as seeds."""

    def __init__(self, seed: int) -> None:
        self.state = seed & 0xFFFFFFFF or 1

    def next(self) -> int:
        x = self.state
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.state = x
        return x

    def below(self, n: int) -> int:
        return self.next() % n

    def between(self, lo: int, hi: int) -> int:
        """Uniform-ish integer in lo..hi inclusive."""
        return lo + self.below(hi - lo + 1)


def distances(rgb):
    return [sum((a - b) ** 2 for a, b in zip(rgb, c)) for c in PALETTE]


def tie_colours(limit: int) -> list[tuple[int, int, int]]:
    """Colours whose smallest palette distance is shared by two or more
    palette colours (the lowest index must win)."""
    found = []
    for r in range(0, 256, 5):
        for g in range(0, 256, 5):
            for b in range(0, 256, 5):
                d = distances((r, g, b))
                if d.count(min(d)) > 1:
                    found.append((r, g, b))
    # Ties sit on planes between two colours; a coarse grid misses most of
    # them, so add the exact midpoints along single channels as well.
    for i, c1 in enumerate(PALETTE):
        for c2 in PALETTE[i + 1:]:
            mid = tuple((a + b) // 2 for a, b in zip(c1, c2))
            if all((a + b) % 2 == 0 for a, b in zip(c1, c2)):
                d = distances(mid)
                if d.count(min(d)) > 1:
                    found.append(mid)
    rng = Rng(0x7135)
    picked = []
    seen = set()
    while found and len(picked) < limit:
        c = found.pop(rng.below(len(found)))
        if c not in seen:
            seen.add(c)
            picked.append(c)
    return picked


def coarse_nearest(rgb) -> int:
    """The nearest colour of ``rgb`` with the low 2 bits of each channel
    cleared: what a search at 6 bits per channel finds."""
    return nearest(*(v & ~3 for v in rgb))


def boundary_colours(limit: int) -> list[tuple[int, int, int]]:
    """Colours near a decision boundary whose exact nearest colour differs
    from coarse_nearest. The first three are worked examples:

    - (0, 128, 129): blue (32 260) beats green (32 770); coarse: green.
    - (255, 190, 5): yellow and orange tie (4 250), the lower index wins;
      coarse: orange.
    - (127, 128, 255): white and blue tie (32 513), the lower index wins;
      coarse: blue.
    """
    picked = [(0, 128, 129), (255, 190, 5), (127, 128, 255)]
    assert [nearest(*c) for c in picked] == [3, 5, 1]
    found = [(r, g, b)
             for r in range(1, 256, 6) for g in range(1, 256, 6) for b in range(1, 256, 6)
             if nearest(r, g, b) != coarse_nearest((r, g, b))]
    rng = Rng(0xB0DE)
    while found and len(picked) < limit:
        c = found.pop(rng.below(len(found)))
        if c not in picked:
            picked.append(c)
    assert all(nearest(*c) != coarse_nearest(c) for c in picked)
    return picked


def picture(name: str, width: int, height: int, pixel) -> dict:
    """``pixel(x, y)`` gives the RGB of (x, y)."""
    pixels = [pixel(x, y) for y in range(height) for x in range(width)]
    for p in pixels:
        assert len(p) == 3 and all(isinstance(v, int) and 0 <= v <= 255 for v in p), (name, p)
    return {"name": name, "width": width, "height": height, "pixels": pixels}


def pictures() -> list[dict]:
    out = []

    for name, rgb in [
        ("1x1 mid grey", (128, 128, 128)),
        ("1x1 yellow / orange tie", (255, 190, 0)),
        ("1x1 near black", (3, 2, 1)),
        ("1x1 violet", (90, 60, 200)),
    ]:
        out.append(picture(name, 1, 1, lambda x, y, rgb=rgb: rgb))

    out.append(picture("7x5 palette colours", 7, 5, lambda x, y: PALETTE[(x + 2 * y) % 7]))

    ties = tie_colours(35)
    assert len(ties) == 35, len(ties)
    out.append(picture("7x5 palette ties", 7, 5, lambda x, y: ties[y * 7 + x]))

    rng = Rng(0x5EED)
    noise_small = [(rng.below(256), rng.below(256), rng.below(256)) for _ in range(35)]
    out.append(picture("7x5 noise", 7, 5, lambda x, y: noise_small[y * 7 + x]))

    out.append(picture("40x30 grey ramp", 40, 30, lambda x, y: (x * 255 // 39,) * 3))
    out.append(picture("40x30 colour ramp", 40, 30, lambda x, y: (
        x * 255 // 39, y * 255 // 29, 255 - (x + y) * 255 // 68)))

    # Dark picture with saturated dark spots: choosing blue, red or green for
    # a spot leaves a negative error in the other channels, which pushes the
    # dark neighbours below zero (the lift rule).
    rng = Rng(0xB1AC)
    spots = [(0, 0, 150), (150, 0, 0), (0, 140, 0), (40, 40, 200), (200, 30, 30), (20, 160, 20)]
    dark = []
    for _ in range(40 * 30):
        if rng.below(5) == 0:
            dark.append(spots[rng.below(len(spots))])
        else:
            dark.append((rng.between(0, 18), rng.between(0, 18), rng.between(0, 18)))
    out.append(picture("40x30 near black with dark colours", 40, 30, lambda x, y: dark[y * 40 + x]))

    # Light picture with mid-tone spots: a spot that maps to black or to a
    # saturated colour leaves a positive error, which pushes the light
    # neighbours above 255 (the scale rule).
    rng = Rng(0x1A17)
    mids = [(127, 127, 127), (120, 60, 200), (100, 200, 90), (200, 110, 40), (126, 126, 250)]
    light = []
    for _ in range(40 * 30):
        if rng.below(5) == 0:
            light.append(mids[rng.below(len(mids))])
        else:
            light.append((rng.between(236, 255), rng.between(236, 255), rng.between(236, 255)))
    out.append(picture("40x30 near white with mid tones", 40, 30, lambda x, y: light[y * 40 + x]))

    rng = Rng(0xC0FFEE)
    noise = [(rng.below(256), rng.below(256), rng.below(256)) for _ in range(64 * 48)]
    out.append(picture("64x48 noise", 64, 48, lambda x, y: noise[y * 64 + x]))

    # Smooth photo-like picture: a hue sweep across, darker towards the
    # bottom, with mild noise.
    rng = Rng(0x0F070)

    def photo(x: int, y: int) -> tuple[int, int, int]:
        t = x * 6 * 255 // 63  # 0 .. 6 * 255 across the width
        seg, f = divmod(t, 255)
        rise, fall = f, 255 - f
        r, g, b = [
            (255, rise, 0), (fall, 255, 0), (0, 255, rise),
            (0, fall, 255), (rise, 0, 255), (255, 0, fall), (255, 0, 0),
        ][seg]
        shade = 255 - y * 200 // 47
        jitter = rng.between(-6, 6)
        return tuple(max(0, min(255, v * shade // 255 + jitter)) for v in (r, g, b))

    out.append(picture("64x48 hue sweep", 64, 48, photo))

    # Blocks alternating between near black and near white with saturated
    # pixels sprinkled in: both range rules fire many times.
    rng = Rng(0xE7E7)

    def extremes(x: int, y: int) -> tuple[int, int, int]:
        roll = rng.below(7)
        if roll == 0:
            return PALETTE[2 + rng.below(5)]
        if roll == 1:
            return (rng.below(256), rng.below(256), rng.below(256))
        if ((x // 8) + (y // 6)) % 2:
            return (rng.between(240, 255), rng.between(240, 255), rng.between(240, 255))
        return (rng.between(0, 15), rng.between(0, 15), rng.between(0, 15))

    out.append(picture("64x48 extremes", 64, 48, extremes))

    # The factor is weight / 42 * strength in that order: at some strengths
    # weight * strength / 42 rounds the other way. Each picture spreads an
    # error that is exactly such a case onto a neighbour sitting on the
    # yellow / orange tie (G = 190), so the order decides that neighbour's
    # colour. At strength 0.35 the first pixel's G error 105 adds
    # trunc(105 * (8 / 42 * 0.35)) = 6 (not 7) to the second pixel; at 0.7 an
    # error of 30 adds 3 (not 4).
    for name, error, strength in [("2x1 factor order at 0.35", 105, 0.35), ("2x1 factor order at 0.7", 30, 0.7)]:
        added = int(error * (8 / 42.0 * strength))
        assert added != int(error * (8 * strength / 42.0))
        pic = picture(name, 2, 1, lambda x, y, e=error, a=added: (0, e, 0) if x == 0 else (255, 189 - a, 0))
        pic["strengths"] = (strength, 1.0, 0.0)
        out.append(pic)

    # Without dithering (strength 0) the exact nearest colour is expected; a
    # coarser search would pick another colour for every pixel here.
    edges = boundary_colours(16)
    pic = picture("8x2 nearest colour boundaries", 8, 2, lambda x, y: edges[y * 8 + x])
    pic["strengths"] = (0.0, 1.0)
    out.append(pic)
    return out


def dither(pic: dict, strength: float) -> dict:
    stats = RangeStats()
    indices = stucki(pic["width"], pic["height"], pic["pixels"], strength, stats)
    assert len(indices) == pic["width"] * pic["height"]
    assert max(indices) < len(PALETTE)
    if strength == 0.0:
        for p, i in zip(pic["pixels"], indices):
            d = distances(p)
            assert i == d.index(min(d)), (pic["name"], p, i)
    return {
        "strength": strength,
        "indices": "".join(f"{i:x}" for i in indices),
        "lift": stats.lift,
        "scale": stats.scale,
    }


def keep_in_range_cases() -> list[dict]:
    inputs = [
        (0, 0, 0), (255, 255, 255), (12, 200, 99),
        (-1, 0, 0), (-1, 255, 255), (0, -1, 128), (-2, -2, -2), (-48, 10, 300),
        (256, 0, 0), (0, 256, 255), (300, 300, 300), (304, 255, 0), (255, 256, 255),
        (-100, 300, 50), (-60, 290, 290), (-255, 0, 0), (-300, -300, 600), (600, -20, 77),
        (371, -29, 121), (511, 0, 0), (-510, 255, 255), (1000, 999, 998),
    ]
    rng = Rng(0x4A11)
    for _ in range(120):  # values error diffusion can produce
        inputs.append(tuple(rng.between(-60, 315) for _ in range(3)))
    for _ in range(60):  # far outside, for the arithmetic
        inputs.append(tuple(rng.between(-700, 900) for _ in range(3)))
    return [{"in": list(c), "out": list(keep_in_range(*c))} for c in inputs]


def build() -> dict:
    images = []
    for pic in pictures():
        images.append({
            "name": pic["name"],
            "width": pic["width"],
            "height": pic["height"],
            "rgb": bytes(v for p in pic["pixels"] for v in p).hex(),
            "results": [dither(pic, s) for s in pic.get("strengths", STRENGTHS)],
        })
    full = [r for img in images for r in img["results"] if r["strength"] == 1.0]
    assert sum(r["lift"] for r in full) > 0 and sum(r["scale"] for r in full) > 0
    return {
        "version": 1,
        "description": ("Stucki error diffusion onto the 7-colour palette. rgb: hex, 3 bytes per pixel, "
                        "row-major; indices: one hex digit per pixel, row-major. lift / scale: how often "
                        "the two range rules fired (information only). Strength 0 is also the expected "
                        "output without dithering: the exact nearest colour (full 8-bit channels, smallest "
                        "squared distance, lowest index on a tie), not a search at reduced channel "
                        "precision; the 'nearest colour boundaries' picture pins colours where the two differ."),
        "kernel": [list(t) for t in KERNEL],
        "divisor": DIVISOR,
        "strengths": list(STRENGTHS),
        "keep_in_range": keep_in_range_cases(),
        "images": images,
    }


def dumps(data: dict) -> str:
    """Readable JSON that keeps long strings and short arrays on one line."""
    lines = ["{"]
    keys = list(data)
    for n, key in enumerate(keys):
        comma = "," if n < len(keys) - 1 else ""
        value = data[key]
        if key in ("keep_in_range", "images"):
            lines.append(f" {json.dumps(key)}: [")
            for m, item in enumerate(value):
                item_comma = "," if m < len(value) - 1 else ""
                if key == "images":
                    lines.append("  {")
                    fields = list(item)
                    for k, field in enumerate(fields):
                        field_comma = "," if k < len(fields) - 1 else ""
                        if field == "results":
                            lines.append('   "results": [')
                            for q, res in enumerate(item[field]):
                                res_comma = "," if q < len(item[field]) - 1 else ""
                                lines.append(f"    {json.dumps(res)}{res_comma}")
                            lines.append(f"   ]{field_comma}")
                        else:
                            lines.append(f"   {json.dumps(field)}: {json.dumps(item[field])}{field_comma}")
                    lines.append(f"  }}{item_comma}")
                else:
                    lines.append(f"  {json.dumps(item)}{item_comma}")
            lines.append(f" ]{comma}")
        else:
            lines.append(f" {json.dumps(key)}: {json.dumps(value)}{comma}")
    lines.append("}")
    text = "\n".join(lines) + "\n"
    assert json.loads(text) == data
    return text


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    default = os.path.join(here, "..", "..", "shared", "vectors", "dither-vectors.json")
    out = os.path.normpath(sys.argv[1] if len(sys.argv) > 1 else default)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(build()))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
