"""Subset Noto Sans CJK TC to the characters the calendar pages need.

    python scripts/subset_font.py <dir with NotoSansCJKtc-Regular.otf/-Bold.otf> src/ulani_epaper/fonts

Source: https://github.com/notofonts/noto-cjk, Sans/OTF/TraditionalChinese/
NotoSansCJKtc-{Regular,Bold}.otf, SIL Open Font License 1.1 (no Reserved
Font Name; the copyright and licence entries of the name table are kept).

Why this source: the region subset Noto Sans TC (Sans/SubsetOTF/TC) used
before has Traditional Chinese only, so fonts.clean() silently dropped every
Simplified Chinese character (们 这 简 为 说 时 议 ...), all Hangul and the
kana marks Big5 lacks (ー ・) from event titles. Noto Sans CJK TC maps the
same Traditional Chinese glyphs by default and also has the Simplified
Chinese, Japanese and Korean characters.

Kept: every character encodable in one or two bytes of
  Big5          ~13,000 Traditional Chinese characters plus symbols
  GB2312        6,763 Simplified Chinese characters plus symbols
  EUC-JP        JIS X 0208: Japanese kanji, kana and symbols (the three-byte
                JIS X 0212 codes are left out)
  EUC-KR        KS X 1001: the 2,350 common Hangul syllables, the Hangul
                jamo and 4,888 hanja (the other syllables, which Python's
                codec spells as eight-byte sequences, are left out)
plus EXTRA_RANGES (ASCII, Latin-1, punctuation, arrows, shapes, dingbats,
CJK symbols, kana, bopomofo, full-width forms). Characters of these sets the
font has no glyph for are skipped. OpenType layout keeps the default and
Traditional Chinese language systems only (see LAYOUT_SCRIPTS), so every
character keeps its Traditional Chinese form. Requires fontTools.
"""

import os
import sys

from fontTools import subset

CHARSETS = ["big5", "gb2312", "euc_jp", "euc_kr"]

EXTRA_RANGES = [
    (0x0020, 0x007E),  # ASCII
    (0x00A0, 0x00FF),  # Latin-1
    (0x2000, 0x206F),  # general punctuation (… ‧ – —)
    (0x2190, 0x21FF),  # arrows
    (0x2500, 0x25FF),  # box drawing, geometric shapes (□ ■ ○ ●)
    (0x2600, 0x27BF),  # misc symbols, dingbats (✓ ✔)
    (0x3000, 0x303F),  # CJK symbols and punctuation
    (0x3040, 0x30FF),  # hiragana, katakana (ー ・)
    (0x3100, 0x312F),  # bopomofo
    (0x31A0, 0x31BF),  # bopomofo extended
    (0x31F0, 0x31FF),  # katakana phonetic extensions
    (0xFF00, 0xFFEF),  # full-width forms
]

# OpenType layout: every script's default language system and Traditional
# Chinese (ZHT) only, as in the Noto Sans TC subset used before. The JAN,
# KOR, ZHS and ZHH systems swap in Japanese, Korean, Simplified Chinese and
# Hong Kong glyph forms through 'locl': dropping them saves ~15,500 glyphs
# (4 MB per weight), keeps the Traditional Chinese forms Pillow draws in
# every renderer, and keeps the format 4 cmap under its 64 KB limit (the
# alternates sit between the default glyphs and break up the ID runs).
SCRIPTS = ["DFLT", "cyrl", "grek", "hang", "hani", "kana", "latn"]
LAYOUT_SCRIPTS = [f"{script}.{lang}" for script in SCRIPTS for lang in ("dflt", "ZHT")]


def in_charset(char: str, codec: str) -> bool:
    try:
        return len(char.encode(codec)) <= 2
    except UnicodeEncodeError:
        return False


def wanted_codepoints() -> list[int]:
    cps = set()
    for cp in range(0x20, 0x10000):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        if any(in_charset(chr(cp), codec) for codec in CHARSETS):
            cps.add(cp)
    for lo, hi in EXTRA_RANGES:
        cps.update(range(lo, hi + 1))
    return sorted(cps)


def main(src_dir: str, out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    cps = wanted_codepoints()
    for weight in ("Regular", "Bold"):
        src = os.path.join(src_dir, f"NotoSansCJKtc-{weight}.otf")
        out = os.path.join(out_dir, f"NotoSansCJKtc-{weight}-subset.otf")
        options = subset.Options()
        options.layout_features = ["*"]
        options.layout_scripts = LAYOUT_SCRIPTS
        options.name_IDs = ["*"]
        options.name_languages = ["*"]
        options.notdef_outline = True
        font = subset.load_font(src, options)
        sub = subset.Subsetter(options)
        sub.populate(unicodes=cps)
        sub.subset(font)
        subset.save_font(font, out, options)
        print(f"{out}: {os.path.getsize(out) / 1e6:.1f} MB, {len(cps)} code points requested")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
