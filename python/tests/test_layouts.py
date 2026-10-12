import functools
import json
from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest
from PIL import Image, ImageChops

from ulani_epaper import image as im
from ulani_epaper import layouts
from ulani_epaper.agenda import AgendaData, Event, Task

FIXTURES = Path(__file__).resolve().parents[2] / "shared" / "layouts" / "agenda"
GOLDEN = FIXTURES / "golden"
TPE = timezone(timedelta(hours=8))
PALETTE = {c.rgb for c in im.PALETTE}
PAGES = {"month": layouts.render_month, "agenda": layouts.render_agenda, "todo": layouts.render_todo,
         "day": layouts.render_day, "monthgrid": layouts.render_monthgrid}


def fixture(name):
    obj = json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))
    return AgendaData.from_json(json.dumps(obj)), date.fromisoformat(obj["today"])


def check(img):
    assert img.size == (800, 480)
    colours = {c for _, c in img.convert("RGB").getcolors(1 << 20)}
    assert colours <= PALETTE, colours - PALETTE
    assert len(colours) >= 2  # something was drawn
    assert im.preview(im.encode(img, dither=False)).tobytes() == img.convert("RGB").tobytes()


NAMES = ["sample", "empty", "busy", "midday"]


@pytest.mark.parametrize("page", sorted(PAGES))
@pytest.mark.parametrize("name", NAMES)
def test_every_page_renders_every_fixture_in_palette_colours(page, name):
    data, today = fixture(name)
    check(PAGES[page](data, today, TPE))


@pytest.mark.parametrize("page", sorted(PAGES))
def test_rendering_is_deterministic(page):
    data, today = fixture("busy")
    assert PAGES[page](data, today, TPE).tobytes() == PAGES[page](data, today, TPE).tobytes()


@pytest.mark.parametrize("today", [date(2026, 2, 14), date(2026, 8, 20), date(2026, 8, 31), date(2026, 3, 1),
                                   date(2026, 12, 31), date(2027, 1, 1)])
def test_month_handles_four_five_and_six_week_months(today):
    data, _ = fixture("sample")
    check(layouts.render_month(data, today, TPE))


def test_today_is_marked_in_red_on_the_month():
    data, today = fixture("empty")
    img = layouts.render_month(data, today, TPE)
    assert (255, 0, 0) in {c for _, c in img.getcolors(1 << 20)}


def test_extremes_do_not_break_the_pages():
    data, today = fixture("sample")
    long_title = "超長標題" * 75  # 300 characters
    at = datetime(2026, 10, 12, 8, tzinfo=TPE)
    extreme = replace(data,
                      events=data.events + (Event(long_title, at, at + timedelta(hours=1), color="#gggggg"),
                                            Event("", at, at, calendar="", color="")),
                      tasks=data.tasks + tuple(Task(f"任務 {i}") for i in range(200)) + (Task(long_title),))
    for render in PAGES.values():
        check(render(extreme, today, TPE))


def recorded_texts(monkeypatch, render, data, today):
    """Every string a page draws, with its bounding box."""
    from PIL import ImageDraw

    texts, original = [], ImageDraw.ImageDraw.text

    def recording(self, xy, text, fill=None, font=None, anchor=None, *args, **kwargs):
        texts.append((text, self.textbbox(xy, text, font=font, anchor=anchor)))
        return original(self, xy, text, fill, font, anchor, *args, **kwargs)

    monkeypatch.setattr(ImageDraw.ImageDraw, "text", recording)
    render(data, today, TPE)
    return texts


@pytest.mark.parametrize("page", sorted(PAGES))
@pytest.mark.parametrize("name", NAMES)
def test_text_stays_on_the_canvas_drawable_and_never_overlaps(monkeypatch, page, name):
    from ulani_epaper import fonts

    data, today = fixture(name)
    texts = recorded_texts(monkeypatch, PAGES[page], data, today)
    assert texts
    for text, (left, top, right, bottom) in texts:
        assert left >= 0 and top >= 0 and right <= 800 and bottom <= 480, (text, "off the canvas")
        assert [c for c in text if c != " " and not fonts.has_glyph(c)] == [], (text, "undrawable")
    boxes = [(s, bb) for s, bb in texts if s.strip()]
    for i, (s1, a) in enumerate(boxes):
        for s2, b in boxes[i + 1:]:
            overlap_w = min(a[2], b[2]) - max(a[0], b[0])
            overlap_h = min(a[3], b[3]) - max(a[1], b[1])
            assert not (overlap_w >= 2 and overlap_h >= 2), (s1, a, s2, b)


def test_events_in_other_time_zones_land_on_their_local_day():
    utc_late = datetime(2026, 10, 12, 17, 30, tzinfo=timezone.utc)  # 01:30 on the 13th in Taipei
    data = AgendaData(events=(Event("深夜航班", utc_late, utc_late + timedelta(hours=2), color="#4986e7"),))
    on_12th = layouts.drawn_texts(layouts.render_agenda, data, date(2026, 10, 12), TPE)
    on_13th = layouts.drawn_texts(layouts.render_agenda, data, date(2026, 10, 13), TPE)
    assert "今天沒有行程" in on_12th  # not today on the 12th ...
    assert on_12th[on_12th.index("13"):on_12th.index("13") + 5] == ["13", "明天", "01:30", "03:30", "深夜航班"]
    assert "接下來" in on_13th and "01:30 – 03:30" in on_13th  # ... but the next event on the 13th


# --- exact strings -------------------------------------------------------------------


@pytest.mark.parametrize("page", sorted(PAGES))
@pytest.mark.parametrize("name", NAMES)
def test_draws_exactly_the_golden_text(page, name):
    # pixels are compared with a tolerance; times, counts and labels must match exactly
    data, today = fixture(name)
    expected = (GOLDEN / f"{page}_{name}.txt").read_text(encoding="utf-8").splitlines()
    assert layouts.drawn_texts(PAGES[page], data, today, TPE) == expected


def test_midday_shows_what_is_next_and_counts_what_ended():
    data, today = fixture("midday")  # synced at 13:30
    texts = layouts.drawn_texts(layouts.render_agenda, data, today, TPE)
    assert texts[texts.index("接下來") + 1:texts.index("接下來") + 3] == ["牙醫回診", "14:00 – 15:00"]
    assert "稍早已結束 2 項" in texts  # 晨會 09:00-09:30 and the 10:00-11:30 review


def test_the_sync_stamp_is_the_date_only():
    # two syncs on the same day with nothing starting or ending in between draw
    # the same pages, so the device skips them (sample: first event at 09:00)
    data, today = fixture("sample")
    later = replace(data, fetched_at=datetime(2026, 10, 12, 8, 45, tzinfo=TPE))
    for render in PAGES.values():
        assert render(data, today, TPE).tobytes() == render(later, today, TPE).tobytes()
    assert "更新於 10/12" in layouts.drawn_texts(layouts.render_todo, data, today, TPE)


# --- helpers ---------------------------------------------------------------------------


def at(day, hh, mm=0):
    return datetime(2026, 10, day, hh, mm, tzinfo=TPE)


def ev(start, end, all_day=False):
    return Event("x", start, end, all_day=all_day)


DAY = date(2026, 10, 12)


@pytest.mark.parametrize("event, text", [
    (ev(at(12, 10), at(12, 11, 30)), "10:00 – 11:30"),
    (ev(at(12, 23), at(13, 0)), "23:00 – 00:00"),
    (ev(at(12, 23), at(13, 1)), "23:00 – 隔天 01:00"),
    (ev(at(12, 20), at(14, 20)), "20:00 – 10月14日 20:00"),
    (ev(at(11, 22), at(12, 2)), "至 02:00"),
    (ev(at(12, 8), at(12, 8)), "08:00"),
    (ev(date(2026, 10, 12), date(2026, 10, 13), True), "全天"),
    (ev(date(2026, 10, 10), date(2026, 10, 13), True), "全天·第 3 天，共 3 天"),
    (ev(at(12, 0), at(13, 0)), "全天"),  # exactly 24 h counts as all day
])
def test_range_text(event, text):
    assert layouts._range_text(event, DAY, TPE) == text


@pytest.mark.parametrize("event, start, end", [
    (ev(at(12, 9), at(12, 9, 30)), "09:00", "09:30"),
    (ev(at(12, 23), at(13, 1)), "23:00", "01:00"),  # early next morning: unambiguous
    (ev(at(12, 20), at(14, 9)), "20:00", "10/14"),
    (ev(at(11, 22), at(12, 2)), "至02:00", ""),
    (ev(at(12, 8), at(12, 8)), "08:00", ""),
    (ev(date(2026, 10, 12), date(2026, 10, 13), True), "全天", ""),
])
def test_time_column_labels(event, start, end):
    assert (layouts._start_label(event, DAY, TPE), layouts._end_label(event, DAY, TPE)) == (start, end)


@pytest.mark.parametrize("fetched, now", [
    (at(12, 7), at(12, 7)),
    (at(11, 23), at(12, 0)),  # synced the day before: start of today
    (None, at(12, 0)),
    (datetime(2026, 10, 12, 7), at(12, 0)),  # naive: ignored
    (datetime(2026, 10, 11, 23, 30, tzinfo=timezone.utc), at(12, 7, 30)),  # another zone
])
def test_now_is_the_sync_time_on_today(fetched, now):
    assert layouts._now(AgendaData(fetched_at=fetched), DAY, TPE) == now


@pytest.mark.parametrize("text, lines", [
    ("讀完《原子習慣》", ["讀完《原子習", "慣》"]),  # 》 may not start a line
    ("繳交第三季報告，週五前", ["繳交第三季報", "告，週五前"]),  # neither may ，
    ("短標題", ["短標題"]),
    ("一二三四五六七八九十一二三四五六七八", ["一二三四五六七", "八九十一二三…"]),
])
def test_wrap_never_starts_a_line_with_closing_punctuation(text, lines):
    font = layouts._font(40, True)
    assert layouts._wrap(text, font, 7 * 40, 2) == lines


@pytest.mark.parametrize("raw, shown", [
    ("", "（無標題）"), ("   ", "（無標題）"), ("🎂🎉", "（無法顯示的標題）"), ("🎂 生日", "生日"),
])
def test_titles(raw, shown):
    assert layouts._title(raw) == shown


# --- golden renders ---------------------------------------------------------------
# Regenerate after an intended design change (and look at every image):
#   python -m ulani_epaper.layouts shared/layouts/agenda shared/layouts/agenda/golden  (from the repo root)
# FreeType versions differ slightly between Pillow builds, so allow a few pixels.
MAX_DIFFERENT = 0.005


@pytest.mark.parametrize("page", sorted(PAGES))
@pytest.mark.parametrize("name", NAMES)
def test_matches_the_golden_render(page, name):
    golden = GOLDEN / f"{page}_{name}.png"
    data, today = fixture(name)
    with Image.open(golden) as g:
        expected = g.convert("RGB")
    actual = PAGES[page](data, today, TPE).convert("RGB")
    diff = ImageChops.difference(actual, expected).convert("L")
    different = 1 - diff.histogram()[0] / (800 * 480)  # share of pixels that are not identical
    assert different <= MAX_DIFFERENT, f"{golden.name}: {different:.2%} of pixels differ"


# --- day and month pages ----------------------------------------------------------------

RED, GREEN, BLACK, WHITE = (255, 0, 0), (0, 255, 0), (0, 0, 0), (255, 255, 255)


def drawn_fills(render, data, today):
    """(text, fill) of every string a page draws."""
    from PIL import ImageDraw

    seen, original = [], ImageDraw.ImageDraw.text

    def recording(self, xy, text, fill=None, *args, **kwargs):
        seen.append((text, fill))
        return original(self, xy, text, fill, *args, **kwargs)

    ImageDraw.ImageDraw.text = recording
    try:
        render(data, today, TPE)
    finally:
        ImageDraw.ImageDraw.text = original
    return seen


def test_month_grid_reddens_only_sundays_and_treats_holidays_as_events():
    data, today = fixture("sample")  # October 2026: Sundays 4, 11, 18, 25; 國慶日 on Saturday the 10th
    red = {t for t, fill in drawn_fills(layouts.render_monthgrid, data, today) if fill == RED}
    assert red == {"日", "4", "11", "18", "25", "10月"}  # the month in the title is the page's accent


def test_month_grid_shows_short_titles_only_where_the_cells_are_tall_enough():
    data, today = fixture("sample")  # five weeks
    assert any(t.startswith("和小陳") for t in layouts.drawn_texts(layouts.render_monthgrid, data, today, TPE))
    at = datetime(2026, 8, 5, 9, tzinfo=TPE)  # August 2026 has six weeks: dots only
    august = AgendaData(events=(Event("和小陳吃午餐", at, at + timedelta(hours=1), color="#4986e7"),))
    texts = layouts.drawn_texts(layouts.render_monthgrid, august, date(2026, 8, 20), TPE)
    assert not any(t.startswith("和小陳") for t in texts)


def test_the_day_page_lists_the_whole_day_even_what_has_ended():
    data, today = fixture("midday")  # synced at 13:30, after 晨會
    texts = layouts.drawn_texts(layouts.render_day, data, today, TPE)
    assert texts[:2] == ["星期一", "12"] and "晨會" in texts and "牙醫回診" in texts


# --- calendar backgrounds -----------------------------------------------------------------


def colours_in(img, box):
    return {c for _, c in img.crop(box).convert("RGB").getcolors(1 << 16)}


def test_text_on_a_background_is_white_with_a_black_outline():
    data, today = fixture("sample")
    green = Image.new("RGB", (800, 480), GREEN)
    weekday = (20, 24, 120, 64)  # "星期一": red bold without a background
    assert RED in colours_in(layouts.render_agenda(data, today, TPE), weekday)
    assert colours_in(layouts.render_agenda(data, today, TPE, green), weekday) == {GREEN, WHITE, BLACK}


def test_dots_and_bars_get_a_black_outline_on_a_background():
    p = layouts._Page(Image.new("RGB", (800, 480), GREEN))
    p.dot(100, 100, 5, "red")  # 95..104
    p.bar(200, 90, 120, "blue", 4)  # x 200..203
    px = p.img.getpixel
    assert (px((100, 100)), px((94, 100)), px((105, 100)), px((100, 80))) == (RED, BLACK, BLACK, GREEN)
    assert (px((201, 100)), px((199, 100)), px((204, 100)), px((201, 120)), px((201, 121)), px((201, 122))) == (
        (0, 0, 255), BLACK, BLACK, (0, 0, 255), BLACK, GREEN)


def test_a_background_changes_no_text_only_how_it_is_drawn():
    data, today = fixture("sample")
    green = Image.new("RGB", (800, 480), GREEN)
    for page, render in PAGES.items():
        assert layouts.drawn_texts(render, data, today, TPE, green) == layouts.drawn_texts(render, data, today, TPE)
        check(render(data, today, TPE, green))


@pytest.mark.parametrize("page", sorted(PAGES))
def test_matches_the_golden_render_on_a_photo(page):
    obj = json.loads((FIXTURES / "photo.json").read_text(encoding="utf-8"))
    data, today = fixture("photo")
    background = photo_background(obj["background"]["image"])
    expected_texts = (GOLDEN / f"{page}_photo.txt").read_text(encoding="utf-8").splitlines()
    assert layouts.drawn_texts(PAGES[page], data, today, TPE, background) == expected_texts
    actual = PAGES[page](data, today, TPE, background).convert("RGB")
    check(actual)
    with Image.open(GOLDEN / f"{page}_photo.png") as g:
        diff = ImageChops.difference(actual, g.convert("RGB")).convert("L")
    different = 1 - diff.histogram()[0] / (800 * 480)
    assert different <= MAX_DIFFERENT, f"{page}_photo: {different:.2%} of pixels differ"


@functools.cache
def photo_background(name):  # dithering a photo takes a few seconds: once
    return layouts.load_background(name, None, FIXTURES)
