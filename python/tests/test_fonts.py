import pytest

from ulani_epaper import fonts


def glyph(font, char):
    mask = font.getmask(char, mode="1")
    return mask.size, bytes(mask)


@pytest.mark.parametrize("bold", [False, True])
def test_bundled_font_loads(bold):
    font = fonts.load(24, bold=bold)
    assert font.getbbox("永恆曆")[2] > 0


@pytest.mark.parametrize("bold", [False, True])
def test_bundled_font_covers_what_the_pages_draw(bold):
    font = fonts.load(24, bold=bold)
    notdef = glyph(font, "")  # private use: not in the font, draws .notdef
    needed = "永恆曆龘行事曆待辦今天明天還有項週一二三四五六日0123456789:–…○●✓→ABCxyz"
    assert [c for c in needed if glyph(font, c) == notdef] == []


@pytest.mark.parametrize("bold", [False, True])
@pytest.mark.parametrize(
    "text",
    [
        "们这简为发说时间会议国际",  # Simplified Chinese (GB2312)
        "ひらがなカタカナ",  # Japanese kana
        "ミーティング・カレンダー",  # kana marks Big5 lacks (ー ・)
        "한국어달력",  # Hangul (KS X 1001)
    ],
)
def test_bundled_font_covers_other_scripts_in_event_titles(bold, text):
    font = fonts.load(24, bold=bold)
    notdef = glyph(font, "")  # private use: not in the font, draws .notdef
    assert [c for c in text if glyph(font, c) == notdef] == []


def test_a_missing_character_is_detectable():
    font = fonts.load(24)
    assert glyph(font, "") == glyph(font, "")


def test_has_glyph():
    assert fonts.has_glyph("曆") and fonts.has_glyph("A") and fonts.has_glyph(" ")
    assert not fonts.has_glyph("🎂") and not fonts.has_glyph("")


def test_clean_drops_what_the_font_cannot_draw():
    assert fonts.clean("🎂 媽媽生日") == "媽媽生日"
    assert fonts.clean("會議‍🧑‍💻 準備") == "會議 準備"
    assert fonts.clean("Line\nbreak\ttab") == "Line break tab"
    assert fonts.clean("☕️ 咖啡") == "咖啡"  # U+2615 + variation selector


def test_coverage_comes_from_the_fonts_character_map():
    # not from how a Pillow build happens to draw a missing glyph (Linux wheels drew
    # U+200D as nothing, Windows as the .notdef box)
    cps = fonts.codepoints()
    assert len(cps) > 20000 and ord("曆") in cps and ord("们") in cps and ord("한") in cps
    assert 0x1F382 not in cps and 0xE000 not in cps


def test_invisible_format_characters_are_always_dropped():
    for c in "​‌‍⁠️﻿":
        assert not fonts.has_glyph(c), hex(ord(c))


def test_pages_use_the_basic_layout_engine_everywhere():
    from PIL import ImageFont

    # Raqm (in Linux wheels) kerns Latin text differently: keep every platform identical
    assert fonts.load(20).layout_engine == ImageFont.Layout.BASIC


def test_clean_composes_decomposed_accents():
    assert fonts.clean("Café 會議") == "Café 會議"


def test_clean_keeps_simplified_chinese_kana_and_hangul():
    assert fonts.clean("这是简体 カレンダー 한국어 달력") == "这是简体 カレンダー 한국어 달력"


def test_bold_and_regular_are_different_files():
    assert fonts.path(bold=True) != fonts.path(bold=False)
