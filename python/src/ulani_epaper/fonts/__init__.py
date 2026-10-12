"""Bundled Noto Sans CJK TC (SIL Open Font License, see OFL.txt).

Subset by scripts/subset_font.py to Big5 + GB2312 + JIS X 0208 + KS X 1001
(Traditional and Simplified Chinese, kana, the common Hangul) + ASCII,
punctuation and symbols, with Traditional Chinese glyph forms, so the
calendar pages render the same glyphs on every OS (and in the Apple apps,
which bundle the same files).
"""

from __future__ import annotations

import os
import struct
import unicodedata
from functools import lru_cache

from PIL import ImageFont

_DIR = os.path.dirname(os.path.abspath(__file__))


def path(bold: bool = False) -> str:
    return os.path.join(_DIR, f"NotoSansCJKtc-{'Bold' if bold else 'Regular'}-subset.otf")


@lru_cache(maxsize=64)
def load(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    # Basic layout on every platform: Raqm (in Pillow's Linux and macOS wheels)
    # kerns Latin text, which changes widths, truncation and the drawn pages.
    return ImageFont.truetype(path(bold), size, layout_engine=ImageFont.Layout.BASIC)


def _cmap(data: bytes) -> frozenset[int]:
    """Code points mapped to a glyph, from the font's cmap table (format 12 or 4)."""
    tables = struct.unpack(">H", data[4:6])[0]
    for i in range(tables):
        tag, _, offset, length = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
        if tag == b"cmap":
            cmap = data[offset:offset + length]
            break
    else:
        raise ValueError("font has no cmap table")
    subtables = {}
    for i in range(struct.unpack(">H", cmap[2:4])[0]):
        platform, encoding, off = struct.unpack(">HHI", cmap[4 + 8 * i:12 + 8 * i])
        subtables[(platform, encoding)] = off
    for key in ((3, 10), (0, 4), (3, 1), (0, 3)):
        off = subtables.get(key)
        if off is None:
            continue
        fmt = struct.unpack(">H", cmap[off:off + 2])[0]
        if fmt == 12:
            groups = struct.unpack(">I", cmap[off + 12:off + 16])[0]
            out = set()
            for g in range(groups):
                start, end, first_glyph = struct.unpack(">III", cmap[off + 16 + 12 * g:off + 28 + 12 * g])
                out.update(c for c in range(start, end + 1) if first_glyph + c - start)
            return frozenset(out)
        if fmt == 4:
            segs = struct.unpack(">H", cmap[off + 6:off + 8])[0] // 2
            ends = struct.unpack(f">{segs}H", cmap[off + 14:off + 14 + 2 * segs])
            base = off + 16 + 2 * segs
            starts = struct.unpack(f">{segs}H", cmap[base:base + 2 * segs])
            deltas = struct.unpack(f">{segs}h", cmap[base + 2 * segs:base + 4 * segs])
            range_offsets_at = base + 4 * segs
            out = set()
            for s in range(segs):
                ro_pos = range_offsets_at + 2 * s
                range_offset = struct.unpack(">H", cmap[ro_pos:ro_pos + 2])[0]
                for c in range(starts[s], ends[s] + 1):
                    if c == 0xFFFF:
                        continue
                    if range_offset == 0:
                        glyph = (c + deltas[s]) & 0xFFFF
                    else:
                        at = ro_pos + range_offset + 2 * (c - starts[s])
                        glyph = struct.unpack(">H", cmap[at:at + 2])[0]
                        glyph = (glyph + deltas[s]) & 0xFFFF if glyph else 0
                    if glyph:
                        out.add(c)
            return frozenset(out)
    raise ValueError("font has no Unicode cmap subtable of format 4 or 12")


@lru_cache(maxsize=1)
def codepoints() -> frozenset[int]:
    """Every character the bundled fonts map (both weights are subset to the same set)."""
    with open(path(), "rb") as f:
        return _cmap(f.read())


@lru_cache(maxsize=4096)
def has_glyph(char: str) -> bool:
    """True if the bundled fonts can draw ``char``. Invisible format characters
    (zero-width joiners, variation selectors, BOM) count as not drawable."""
    if unicodedata.category(char) == "Cf" or 0xFE00 <= ord(char) <= 0xFE0F or 0xE0100 <= ord(char) <= 0xE01EF:
        return False
    return ord(char) in codepoints()


def clean(text: str) -> str:
    """Text as the pages can draw it: composed (NFC, so a decomposed "Café"
    keeps its é), emoji and other missing characters dropped, line breaks and
    tabs turned into spaces, runs of spaces folded."""
    text = unicodedata.normalize("NFC", text)
    text = "".join(" " if c.isspace() or unicodedata.category(c) == "Cc" else c for c in text)
    return " ".join("".join(c for c in text if c == " " or has_glyph(c)).split())
