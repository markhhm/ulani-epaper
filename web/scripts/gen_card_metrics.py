"""Write web/test/fixtures/card-metrics.json: the bold font's advance widths and the extent of 國
for every character and size the shared card fixtures (shared/layouts/card/*.json) use, so the card
layout in web/src/core/cardLayout.ts can be tested in Node against the Python goldens' text lists
without a canvas.

The numbers are recorded from the reference implementation, the Python package in this repository
(python/src/ulani_epaper, bundled Noto Sans CJK TC Bold; needs Pillow). From the repository root:

    PYTHONPATH=python/src python web/scripts/gen_card_metrics.py

The script stops unless ulani_epaper is imported from this repository's python/src.
"""

from __future__ import annotations

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.realpath(os.path.join(HERE, "..", ".."))
REFERENCE = os.path.join(ROOT, "python", "src", "ulani_epaper")

try:
    from ulani_epaper import fonts, layouts
except ImportError:
    sys.exit("ulani_epaper is not importable: run with PYTHONPATH=python/src")
if os.path.realpath(os.path.dirname(layouts.__file__)) != REFERENCE:
    sys.exit(f"ulani_epaper comes from {layouts.__file__}, not from {REFERENCE}")

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "web", "test", "fixtures", "card-metrics.json")


def main() -> None:
    sizes: dict[int, set[str]] = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "shared", "layouts", "card", "*.json"))):
        with open(path, encoding="utf-8") as f:
            card = json.load(f)
        for t in card["texts"]:
            chars = sizes.setdefault(t.get("size", 48), {layouts.ELLIPSIS})
            chars.update("".join(fonts.clean(line) for line in t["text"].split("\n")))
    out = {}
    for size, chars in sorted(sizes.items()):
        font = layouts._font(size, True)
        widths = {c: font.getlength(c) for c in sorted(chars)}
        above, below = layouts._glyph_extent(size)
        # The layout adds one width per character; the reference measures whole strings.
        probe = "".join(sorted(chars))
        assert font.getlength(probe) == sum(widths.values()), (size, "advances are not additive")
        out[str(size)] = {"above": above, "below": below, "widths": widths}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"version": 1, "font": "NotoSansCJKtc-Bold-subset.otf, Pillow basic layout",
                   "sizes": out}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
