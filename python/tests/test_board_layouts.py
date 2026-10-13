"""The message board pages: render_board (sticky notes) and render_message (one big note)."""

import json
from datetime import timedelta, timezone
from pathlib import Path

import pytest
from PIL import Image, ImageChops, ImageDraw

from ulani_epaper import fonts, layouts
from ulani_epaper import image as im
from ulani_epaper.notes import Note

FIXTURES = Path(__file__).resolve().parents[2] / "shared" / "layouts" / "board"
GOLDEN = FIXTURES / "golden"
TPE = timezone(timedelta(hours=8))
PALETTE = {c.rgb for c in im.PALETTE}
PAGES = {"board": layouts.render_board, "message": layouts.render_message}
NAMES = ["empty", "short", "long", "six", "eight", "emoji"]
YELLOW, BLACK, WHITE = (255, 255, 0), (0, 0, 0), (255, 255, 255)


def fixture(name):
    obj = json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))
    return [Note(n["id"], n["text"], n["at"], n.get("color", "yellow")) for n in obj["notes"]]


def note(text, color="yellow", at="2026-10-12T14:03:00+08:00", id="a1b2c3d4"):
    return Note(id, text, at, color)


def check(img):
    assert img.size == (800, 480)
    colours = {c for _, c in img.convert("RGB").getcolors(1 << 20)}
    assert colours <= PALETTE, colours - PALETTE
    assert im.preview(im.encode(img, dither=False)).tobytes() == img.convert("RGB").tobytes()


def drawn(render, notes):
    """(text, font size, fill, bounding box) of every string drawn."""
    texts, original = [], ImageDraw.ImageDraw.text

    def recording(self, xy, text, fill=None, font=None, anchor=None, *args, **kwargs):
        texts.append((text, font.size, fill, self.textbbox(xy, text, font=font, anchor=anchor)))
        return original(self, xy, text, fill, font, anchor, *args, **kwargs)

    ImageDraw.ImageDraw.text = recording
    try:
        render(notes, TPE)
    finally:
        ImageDraw.ImageDraw.text = original
    return texts


@pytest.mark.parametrize("page", sorted(PAGES))
@pytest.mark.parametrize("name", NAMES)
def test_every_fixture_renders_in_panel_colours(page, name):
    check(PAGES[page](fixture(name), TPE))


@pytest.mark.parametrize("page", sorted(PAGES))
def test_rendering_is_deterministic(page):
    notes = fixture("six")
    assert PAGES[page](notes, TPE).tobytes() == PAGES[page](notes, TPE).tobytes()


@pytest.mark.parametrize("page", sorted(PAGES))
@pytest.mark.parametrize("name", NAMES)
def test_draws_exactly_the_golden_text(page, name):
    expected = (GOLDEN / f"{page}_{name}.txt").read_text(encoding="utf-8").splitlines()
    assert layouts.drawn_texts(PAGES[page], fixture(name), TPE) == expected


# Regenerate after an intended design change (and look at every image):
#   python -m ulani_epaper.layouts shared/layouts/board shared/layouts/board/golden  (from the repo root)
MAX_DIFFERENT = 0.005


@pytest.mark.parametrize("page", sorted(PAGES))
@pytest.mark.parametrize("name", NAMES)
def test_matches_the_golden_render(page, name):
    golden = GOLDEN / f"{page}_{name}.png"
    with Image.open(golden) as g:
        expected = g.convert("RGB")
    actual = PAGES[page](fixture(name), TPE).convert("RGB")
    diff = ImageChops.difference(actual, expected).convert("L")
    different = 1 - diff.histogram()[0] / (800 * 480)
    assert different <= MAX_DIFFERENT, f"{golden.name}: {different:.2%} of pixels differ"


def test_write_golden_handles_board_fixtures(tmp_path):
    written = layouts.write_golden(str(FIXTURES), str(tmp_path))
    assert sorted(Path(p).name for p in written) == sorted(f"{page}_{name}.png" for page in PAGES for name in NAMES)
    assert (tmp_path / "board_six.txt").read_text(encoding="utf-8") == (GOLDEN / "board_six.txt").read_text(
        encoding="utf-8")


@pytest.mark.parametrize("page", sorted(PAGES))
@pytest.mark.parametrize("name", NAMES)
def test_text_stays_inside_drawable_and_never_overlaps(page, name):
    texts = drawn(PAGES[page], fixture(name))
    assert texts
    for text, _, _, (left, top, right, bottom) in texts:
        assert left >= 0 and top >= 0 and right <= 800 and bottom <= 480, (text, "off the canvas")
        assert [c for c in text if c != " " and not fonts.has_glyph(c)] == [], (text, "undrawable")
    for i, (s1, _, _, a) in enumerate(texts):
        for s2, _, _, b in texts[i + 1:]:
            overlap_w = min(a[2], b[2]) - max(a[0], b[0])
            overlap_h = min(a[3], b[3]) - max(a[1], b[1])
            assert not (overlap_w >= 2 and overlap_h >= 2), (s1, a, s2, b)


def test_no_ink_below_the_bottom_line():
    for page in PAGES.values():
        for name in NAMES:
            img = page(fixture(name), TPE)
            assert img.crop((0, layouts.BOTTOM, 800, 480)).getcolors() == [(800 * (480 - layouts.BOTTOM), WHITE)]


# --- board ---------------------------------------------------------------------------


def bottom_right(i, cols, rows):
    """A point just inside the bottom-right corner of grid cell ``i`` (spec geometry: x 28..772,
    y 84..462, 16 px gaps); text and time never reach it."""
    cw, ch = (744 - (cols - 1) * 16) / cols, (378 - (rows - 1) * 16) / rows
    r, c = divmod(i, cols)
    return round(28 + c * (cw + 16) + cw) - 13, round(84 + r * (ch + 16) + ch) - 13


@pytest.mark.parametrize("n, cols, rows", [(1, 1, 1), (2, 2, 1), (3, 3, 1), (4, 2, 2), (5, 3, 2), (6, 3, 2)])
def test_cards_fill_the_grid_newest_first(n, cols, rows):
    colours = ["blue", "red", "green", "orange", "blue", "red"]
    notes = [note("記得澆花", colours[i], id=f"0000000{i}") for i in range(n)]
    img = layouts.render_board(notes, TPE)
    for i in range(n):
        assert img.getpixel(bottom_right(i, cols, rows)) == im.COLOURS[colours[i]].rgb, i
    if n == 5:
        assert img.getpixel(bottom_right(5, cols, rows)) == WHITE  # the sixth cell stays empty


def test_more_than_six_shows_the_newest_six():
    notes = [note(f"第{i}則", id=f"0000000{i}") for i in range(8)]
    texts = layouts.drawn_texts(layouts.render_board, notes, TPE)
    assert "最新 6 則，共 8 則" in texts
    assert "第0則" in texts and "第5則" in texts and "第6則" not in texts


@pytest.mark.parametrize("colour, ink", [("yellow", BLACK), ("orange", BLACK), ("green", BLACK), ("blue", WHITE),
                                         ("red", WHITE)])
def test_card_text_colour(colour, ink):
    texts = drawn(layouts.render_board, [note("記得澆花", colour)])
    assert {fill for text, _, fill, _ in texts if text in ("記得澆花", "10/12 14:03")} == {ink}


def test_the_yellow_card_has_a_black_keyline():
    img = layouts.render_board([note("x", "yellow")], TPE)
    assert img.getpixel((400, layouts.BOARD_TOP)) == BLACK and img.getpixel((400, layouts.BOARD_TOP + 1)) == YELLOW
    blue = layouts.render_board([note("x", "blue")], TPE)
    assert blue.getpixel((400, layouts.BOARD_TOP)) == (0, 0, 255)


def test_card_text_is_as_large_as_fits():
    short = drawn(layouts.render_board, [note("短")])
    assert [(t, size) for t, size, _, _ in short if t == "短"] == [("短", 44)]
    assert [size for t, size, _, _ in short if t == "10/12 14:03"] == [18]
    long_one = drawn(layouts.render_board, fixture("long"))
    size, = {size for t, size, _, _ in long_one if t not in ("留言板", "1 則", "10/12 14:30")}
    assert size in layouts.CARD_TEXT_SIZES and size < 30
    assert not any(t.endswith("…") for t, *_ in long_one)  # it shrank until all of it fits


def test_text_that_never_fits_ends_with_an_ellipsis():
    notes = [note("字" * 300, id=f"0000000{i}") for i in range(6)]
    texts = drawn(layouts.render_board, notes)
    body = [(t, size) for t, size, _, _ in texts if "字" in t]
    assert {size for _, size in body} == {20}
    assert sum(t.endswith("…") for t, _ in body) == 6  # one cut line per card


def test_line_breaks_are_kept():
    texts = layouts.drawn_texts(layouts.render_board, [note("買牛奶\n繳電費")], TPE)
    assert texts[2:4] == ["買牛奶", "繳電費"]
    texts = layouts.drawn_texts(layouts.render_board, [note("買牛奶\n\n🎂\n繳電費")], TPE)
    assert texts[2:4] == ["買牛奶", "繳電費"]  # empty and undrawable lines leave no gap


@pytest.mark.parametrize("text", ["🎂🎉", "‍"])
def test_undrawable_notes_say_so(text):
    for render in PAGES.values():
        assert "（無法顯示的留言）" in "".join(layouts.drawn_texts(render, [note(text)], TPE))  # may wrap


def test_times_are_shown_in_the_given_time_zone():
    utc_note = note("x", at="2026-10-11T17:05:00+00:00")
    assert "10/12 01:05" in layouts.drawn_texts(layouts.render_board, [utc_note], TPE)
    assert "10/11 17:05" in layouts.drawn_texts(layouts.render_board, [utc_note], timezone.utc)


@pytest.mark.parametrize("render", PAGES.values())
def test_empty_state(render):
    texts = layouts.drawn_texts(render, [], TPE)
    assert texts[1:] == ["還沒有留言", "在 Paperhue 輸入留言，就會顯示在這裡"]


# --- one big message -------------------------------------------------------------------


def test_message_shows_only_the_newest_note():
    notes = [note("新的", id="00000001", at="2026-10-12T18:00:00+08:00"), note("舊的", id="00000002")]
    texts = drawn(layouts.render_message, notes)
    assert [(t, size) for t, size, _, _ in texts] == [("留言", 28), ("10/12 18:00", 18), ("新的", 120)]
    assert texts[0][2] == (255, 0, 0)  # the title is red


@pytest.mark.parametrize("colour, ink", [("yellow", BLACK), ("orange", BLACK), ("red", (255, 0, 0)),
                                         ("blue", (0, 0, 255)), ("green", BLACK)])
def test_message_colour(colour, ink):
    texts = drawn(layouts.render_message, [note("出門了", colour)])
    assert [fill for t, _, fill, _ in texts if t == "出門了"] == [ink]


def test_message_is_centred():
    texts = drawn(layouts.render_message, [note("出門了")])
    (_, _, _, (left, top, right, bottom)), = [t for t in texts if t[0] == "出門了"]
    assert abs((left + right) / 2 - 400) <= 2
    assert abs((top + bottom) / 2 - (layouts.BOARD_TOP + layouts.BOTTOM) / 2) <= 6


def test_message_shrinks_then_cuts():
    sizes = []
    for text in ("好", "晚餐在冰箱，微波 3 分鐘就好", "字" * 60, "字" * 300):
        texts = drawn(layouts.render_message, [note(text)])
        body = [(t, size) for t, size, _, _ in texts if t not in ("留言", "10/12 14:03")]
        sizes.append(body[0][1])
        assert body[-1][0].endswith("…") == (text == "字" * 300)
    assert sizes[0] == 120 and sizes == sorted(sizes, reverse=True) and sizes[-1] == 30


def test_message_lines_are_balanced():
    texts = layouts.drawn_texts(layouts.render_message, [note("（無法顯示的留言）")], TPE)
    assert texts[2:] == ["（無法顯示", "的留言）"]  # not a long line over a short one


def test_fit_note_picks_the_largest_size_that_holds_everything():
    font_w = layouts._font(44, True).getlength("字")
    size, lines = layouts._fit_note(["字" * 8], layouts.CARD_TEXT_SIZES, font_w * 4, 200)
    assert size == 44 and lines == ["字" * 4] * 2
    size, lines = layouts._fit_note(["字" * 100], layouts.CARD_TEXT_SIZES, 200, 60)
    assert size == 20 and lines[-1].endswith("…")


def test_card_text_does_not_end_on_one_character():
    width = layouts._font(44, True).getlength("字") * 4.5  # at 44 px '！' takes '樂' down with it
    assert layouts._fit_note(["生日快樂！"], layouts.CARD_TEXT_SIZES, width, 200) == (44, ["生日快", "樂！"])
    assert layouts._fit_note(["生日快樂！"], layouts.CARD_TEXT_SIZES, width, 200, orphans=False) == (36, ["生日快樂！"])
    # no size avoids it: the largest that fits after all
    narrow = layouts._font(20, True).getlength("字") * 1.5
    assert layouts._fit_note(["字字"], layouts.CARD_TEXT_SIZES, narrow, 400, orphans=False)[0] == 44
    texts = layouts.drawn_texts(layouts.render_board, [note("生日快樂！", id=f"0000000{i}") for i in range(6)], TPE)
    assert texts.count("生日快樂！") == 6
