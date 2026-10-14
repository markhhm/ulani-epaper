"""Write the tables Natural dithering ships (shared/DITHER.md §3).

    python python/tools/natural_tables.py      (from the repository root; needs numpy)

Writes shared/dither/natural-tables.json and its copy inside the package,
python/src/ulani_epaper/data/natural-tables.json (python/tests/test_natural.py
fails if the two differ). The apps load these values and never recompute them.
A measured palette only changes PALETTE_SRGB; after rerunning this, re-pin the
vectors with python/tools/natural_vectors.py.

Every double is written as its shortest round-trip decimal string (Python's
repr); the decode table and the linear palette are also given as hex floats.
"""

from __future__ import annotations

import itertools
import json
import math
import os

import numpy as np

#: Panel colours in sRGB, relative to panel white, from the 7.3-inch ACeP datasheet's L*a*b*:
#: black, white, green, blue, red, yellow, orange (the device's indices 0-6).
PALETTE_SRGB = [(76, 63, 89), (255, 255, 255), (73, 151, 107), (87, 97, 161), (216, 95, 99), (254, 237, 116),
                (236, 126, 103)]
LUMA = (0.2126, 0.7152, 0.0722)  # Rec. 709 luminance of linear sRGB
CONTRAST = 0.3  # the mild S-curve folded into the decode table
SAT, DEAD, KNEE, ALPHA = 1.3, 0.05, 0.8, 1.0
STUCKI = ((8, 1, 0), (4, 2, 0), (2, -2, 1), (4, -1, 1), (8, 0, 1), (4, 1, 1), (2, 2, 1),
          (1, -2, 2), (2, -1, 2), (4, 0, 2), (2, 1, 2), (1, 2, 2))
STUCKI_DIV = 42
#: With the datasheet palette, orange lies 0.0005 inside the black-red-yellow face of the hull,
#: so the hull is a bipyramid only to within 0.0046 (yellow outside the black-red-orange face).
BIPYRAMID_SLACK = 0.01
ABOUT = ("Paperhue Natural dithering tables (shared/DITHER.md §3); datasheet palette; doubles as shortest "
         "round-trip decimal strings; decode/pal_lin also as hex floats")


def srgb_to_lin(x: float) -> float:
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4


def decode_table(contrast: float = 0.0) -> list[float]:
    """Byte -> linear light; with ``contrast``, an S-curve (smoothstep blend) on the sRGB value first."""
    out = []
    for i in range(256):
        x = i / 255
        if contrast:
            x = (1 - contrast) * x + contrast * x * x * (3 - 2 * x)
        out.append(srgb_to_lin(x))
    return out


def hull_facets(pts) -> list[tuple[float, float, float, float]]:
    """Facets of the convex hull of a few 3-D points: (nx, ny, nz, d), unit normal, n.x <= d inside."""
    pts = [np.array(p, float) for p in pts]
    out = []
    for i, j, k in itertools.combinations(range(len(pts)), 3):
        n = np.cross(pts[j] - pts[i], pts[k] - pts[i])
        if np.linalg.norm(n) < 1e-12:
            continue
        n = n / np.linalg.norm(n)
        side = [n @ (p - pts[i]) for q, p in enumerate(pts) if q not in (i, j, k)]
        if all(s <= 1e-12 for s in side):
            out.append((*n, n @ pts[i]))
        elif all(s >= -1e-12 for s in side):
            out.append((*(-n), -(n @ pts[i])))
    return [tuple(float(v) for v in f) for f in out]


def build(palette=PALETTE_SRGB) -> dict:
    lin = decode_table()
    pal_lin = [tuple(lin[c] for c in p) for p in palette]
    facets = hull_facets(pal_lin)
    k, w = np.array(pal_lin[0]), np.array(pal_lin[1])
    wk = w - k
    yk = float(np.dot(LUMA, k))
    yrange = float(np.dot(LUMA, w - k))
    # a basis of the plane across the grey axis, and the 5 inks in angular order around it
    axis = (w - k) / np.linalg.norm(w - k)
    e1 = np.array([1.0, -1.0, 0.0]) - axis * (axis[0] - axis[1])
    e1 /= np.linalg.norm(e1)
    e2 = np.cross(axis, e1)
    xy = {i: (float(e1 @ (np.array(pal_lin[i]) - k)), float(e2 @ (np.array(pal_lin[i]) - k)))
          for i in range(2, len(palette))}
    rim = sorted(xy, key=lambda i: math.atan2(xy[i][1], xy[i][0]))
    sectors = [(rim[i], rim[(i + 1) % len(rim)]) for i in range(len(rim))]
    sector_xy = [(*xy[a], *xy[b]) for a, b in sectors]
    gap = check_bipyramid(pal_lin, facets, sectors, sector_xy)
    print(f"the hull is a bipyramid around the grey axis to within {gap:.4f} in linear light")

    def dec(values):
        return [repr(float(v)) for v in values]

    return {
        "about": ABOUT,
        "palette_srgb": [list(p) for p in palette],
        "decode": dec(decode_table(CONTRAST)),
        "decode_hex": [float(v).hex() for v in decode_table(CONTRAST)],
        "pal_lin": [dec(p) for p in pal_lin],
        "pal_lin_hex": [[float(c).hex() for c in p] for p in pal_lin],
        "k": dec(k),
        "wk": dec(wk),
        "yk": repr(yk),
        "yrange": repr(yrange),
        "e1": dec(e1),
        "e2": dec(e2),
        "facets": [dec(f) for f in facets],
        "sectors": [list(s) for s in sectors],
        "sector_xy": [dec(s) for s in sector_xy],
        "luma": dec(LUMA),
        "sat": repr(SAT), "dead": repr(DEAD), "knee": repr(KNEE), "alpha": repr(ALPHA),
        "stucki": [list(t) for t in STUCKI],
        "stucki_div": STUCKI_DIV,
    }


def check_bipyramid(pal_lin, facets, sectors, sector_xy) -> float:
    """Step A lets a pixel use black, white and the two inks either side of its hue, so the
    hull should be the bipyramid of the five sectors: black or white plus two neighbouring
    inks per face. Returns how far, in linear light, a panel colour lies outside that
    bipyramid; at most BIPYRAMID_SLACK is accepted."""
    pts = [np.array(p) for p in pal_lin]
    corners = set()
    for nx, ny, nz, d in facets:
        n = np.array((nx, ny, nz))
        corners |= {i for i, p in enumerate(pts) if abs(n @ p - d) <= 1e-12}
    assert len(facets) == 10 and corners == set(range(7)), "a panel colour is not a corner of the hull"
    for ax, ay, bx, by in sector_xy:
        assert ax * by - ay * bx > 0, "a hue sector is 180 degrees or wider"
    gap = 0.0
    for tip, other in ((0, 1), (1, 0)):
        for a, b in sectors:
            n = np.cross(pts[a] - pts[tip], pts[b] - pts[tip])
            n /= np.linalg.norm(n)
            d = n @ pts[tip]
            if n @ pts[other] > d:
                n, d = -n, -d
            gap = max(gap, *(float(n @ p - d) for p in pts))
    assert gap <= BIPYRAMID_SLACK, f"the hull is not a bipyramid around the grey axis (off by {gap:.4f})"
    return gap


def dumps(doc: dict) -> str:
    """JSON with one table row per line."""
    def inline(v):
        return json.dumps(v, ensure_ascii=False)

    lines = []
    for n, (key, value) in enumerate(doc.items()):
        comma = "," if n < len(doc) - 1 else ""
        if isinstance(value, list) and (isinstance(value[0], list) or len(value) > 4):
            lines.append(f" {inline(key)}: [")
            lines += [f"  {inline(row)}," for row in value[:-1]] + [f"  {inline(value[-1])}"]
            lines.append(f" ]{comma}")
        else:
            lines.append(f" {inline(key)}: {inline(value)}{comma}")
    text = "{\n" + "\n".join(lines) + "\n}\n"
    assert json.loads(text) == doc
    return text


def main() -> None:
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    text = dumps(build())
    for path in (os.path.join(root, "shared", "dither", "natural-tables.json"),
                 os.path.join(root, "python", "src", "ulani_epaper", "data", "natural-tables.json")):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
