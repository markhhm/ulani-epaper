"""Expected results for the Swift page canvas and the calendar pages, computed with the Python reference.

Writes page-expectations.json next to this file. Run from the repository root with a Python
that has ulani_epaper installed (python/):

    python apple/UlaniKit/Tests/PaperhuePagesTests/Differential/make_page_expectations.py

"shapes": every drawing primitive of layouts._Page over a sweep of sizes, colours and
sub-pixel positions, each drawn alone on a white page. A case is the call, the region it is
read back from (inclusive, every drawn pixel lies inside) and the FNV-1a 64 hash of its
pixels: the non-white runs of the region, row by row, written "y,x0,x1,c" (c the colour's
initial, k for black) and joined by spaces.

"months": render_month for the shared fixtures over several days and zones, for 4-, 5- and
6-week months, the extreme inputs of test_layouts.py and seeded random agendas.
"agendas": render_agenda the same way, plus sync times through the day (the hero's
接下來 / 進行中 and the ended count) and a week across the new year.
"days", "monthgrids": render_day and render_monthgrid over the month page's cases.
"todos": render_todo for the fixtures over several days, lists of 1 to 201 tasks (flat lists
and sections), the year boundary and seeded random task lists. Each
render is the list of drawing calls it makes, in order, one tab-separated line per call:
text (only a string that draws: x, y as drawn, anchor, size, bold 0/1, colour, string),
bar, dot / disc / ring (their box), rect, line, panel, hairline_h, hairline_v, plus. "data" is a
fixture name or AgendaData.to_json(); "zone" is "+HH:MM" or an IANA name (zoneinfo).

The output is deterministic (fixed random seed).
"""

import json
import random
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw

from ulani_epaper import layouts
from ulani_epaper.agenda import AgendaData, Event, Task

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]  # PaperhuePagesTests, Tests, UlaniKit, apple, repository root
FIXTURES = REPO / "shared" / "layouts" / "agenda"
NAMES = ["sample", "empty", "busy", "midday"]

NAME_OF = {rgb: name for name, rgb in layouts.RGB.items()}
INITIAL = {"black": "k", "white": "w", "green": "g", "blue": "b", "red": "r", "yellow": "y", "orange": "o"}
INITIAL_OF = {layouts.RGB[name]: c for name, c in INITIAL.items()}
COLOURS = ["black", "red", "orange", "yellow", "green", "blue"]

rng = random.Random(20261012)


def fnv1a(text: str) -> str:
    h = 0xcbf29ce484222325
    for byte in text.encode("utf-8"):
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def runs(img: Image.Image, region) -> str:
    x0, y0, x1, y1 = region
    px = img.load()
    out = []
    for y in range(y0, y1 + 1):
        x = x0
        while x <= x1:
            c = px[x, y]
            if c == layouts.PAPER:
                x += 1
                continue
            start = x
            while x + 1 <= x1 and px[x + 1, y] == c:
                x += 1
            out.append(f"{y},{start},{x},{INITIAL_OF[c]}")
            x += 1
    return " ".join(out)


def call(page, case):
    kind, *args = case
    rgb = layouts.RGB
    if kind == "disc":
        cx, cy, r, colour = args
        page.disc(cx, cy, r, rgb[colour])
    elif kind == "ring":
        cx, cy, r, colour, width = args
        page.ring(cx, cy, r, rgb[colour], width)
    elif kind == "rect":
        x0, y0, x1, y1, colour = args
        page.rect(x0, y0, x1, y1, rgb[colour])
    elif kind == "line":
        points, colour, width = args
        page.line([tuple(p) for p in points], rgb[colour], width)
    else:  # bar, dot, panel (colour names), hairline_h, hairline_v
        getattr(page, kind)(*args)


def nominal_box(case):
    """(xs, ys, padding) around which the case draws."""
    kind, *args = case
    if kind == "line":
        return [p[0] for p in args[0]], [p[1] for p in args[0]], args[2]
    if kind in ("dot", "disc", "ring"):
        cx, cy, r = args[:3]
        return [cx - r, cx + r], [cy - r, cy + r], 2
    if kind == "bar":
        x, y0, y1, _, w = args
        return [x, x + w], [y0, y1], 2
    if kind == "hairline_h":
        return args[0:2], [args[2]], 2
    if kind == "hairline_v":
        return [args[0]], args[1:3], 2
    return [args[0], args[2]], [args[1], args[3]], 2  # rect, panel


def shape(case):
    """[*case, region, hash]: the call drawn alone on a white page, read back from its region."""
    page = layouts._Page()
    call(page, case)
    xs, ys, pad = nominal_box(case)
    region = [max(0, int(min(xs)) - pad - 2), max(0, int(min(ys)) - pad - 2),
              min(layouts.W - 1, int(max(xs)) + pad + 2), min(layouts.H - 1, int(max(ys)) + pad + 2)]
    drawn = Image.eval(page.img, lambda v: 255 - v).getbbox()  # every pixel that is not white
    if drawn is not None:
        assert region[0] <= drawn[0] and region[1] <= drawn[1] and drawn[2] - 1 <= region[2] \
            and drawn[3] - 1 <= region[3], (case, drawn, region)
    return [*case, region, fnv1a(runs(page.img, region))]


def shape_cases():
    cases = []
    for w in range(1, 9):
        for h in range(1, 49):
            for colour in ("blue", "yellow"):
                cases.append(["bar", 20, 20, 20 + h - 1, colour, w])
    for kind in ("dot", "disc", "ring"):
        for r in range(1, 41):
            for frac in (0.0, 0.25, 0.5, 0.75):
                cx, cy = 60 + frac, 60 + (0.75 - frac)
                if kind == "dot":
                    cases += [["dot", cx, cy, r, colour] for colour in ("red", "yellow")]
                elif kind == "disc":
                    cases.append(["disc", cx, cy, r, "red"])
                else:
                    cases += [["ring", cx, cy, r, "blue", width] for width in (1, 2, 3, 4)]
    for w in (4, 5, 7):  # the tallest bars: cards, list rows, the agenda's hero
        cases += [["bar", 20, 20, 20 + h - 1, colour, w] for h in (60, 100, 161, 378) for colour in ("red", "yellow")]
    for wd, ht, radius in ((744, 378, 12), (364, 181, 12), (237, 181, 12), (744, 181, 12), (68, 68, 10)):
        cases += [["panel", 28, 84, 28 + wd - 1, 84 + ht - 1, colour, radius] for colour in ("blue", "yellow")]
    sizes = [1, 2, 3, 5, 6, 10, 24, 25, 68]
    for wd in sizes:
        for ht in sizes:
            for radius in (0, 1, 2, 3, 10, 12):
                for colour in ("orange", "yellow"):
                    cases.append(["panel", 20, 20, 20 + wd - 1, 20 + ht - 1, colour, radius])
    for _ in range(200):
        x0, y0, x1, y1 = (rng.randint(10, 60) for _ in range(4))
        cases.append(["rect", min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1), rng.choice(COLOURS)])
    for _ in range(200):
        points = [[rng.randint(20, 90), rng.randint(20, 90)] for _ in range(rng.randint(2, 4))]
        cases.append(["line", points, rng.choice(COLOURS), rng.randint(1, 7)])
    cases.append(["line", [[386, 225], [396, 235], [415, 214]], "blue", 4])  # the to-do page's check mark
    for _ in range(40):
        x0, x1 = sorted(rng.randint(5, 120) for _ in range(2))
        cases.append(["hairline_h", x0, x1, rng.randint(5, 120)])
        y0, y1 = sorted(rng.randint(5, 120) for _ in range(2))
        cases.append(["hairline_v", rng.randint(5, 120), y0, y1])
    # off the canvas: clipped, never wrapped
    cases += [["bar", -2, -5, 30, "yellow", 7], ["bar", 796, 470, 490, "red", 7], ["dot", 799.5, 2.25, 5, "yellow"],
              ["disc", -3.0, 478.5, 19, "red"], ["ring", 795.0, 240.0, 13, "blue", 2],
              ["rect", -4, 470, 10, 500, "green"], ["panel", 760, -8, 830, 30, "yellow", 12],
              ["line", [[-10, 470], [30, 490]], "black", 5], ["hairline_h", 790, 810, 479], ["hairline_v", 0, 470, 500]]
    return [shape(c) for c in cases]


# --- month pages ---------------------------------------------------------------------


def logged(render, *args):
    """Every drawing call of render(*args), as one tab-separated line each."""
    ops = []

    def line(*fields):
        ops.append("\t".join(str(f) for f in fields))

    def box(cx, cy, r):
        return round(cx - r), round(cy - r), round(cx + r) - 1, round(cy + r) - 1

    page = layouts._Page
    saved = {name: getattr(page, name) for name in ("bar", "dot", "disc", "ring", "rect", "line", "panel",
                                                    "hairline_h", "hairline_v", "plus")}
    original_text = ImageDraw.ImageDraw.text

    def text(self, xy, s, fill=None, font=None, anchor=None, *a, **k):
        bold = 1 if "Bold" in font.path else 0
        line("text", xy[0], xy[1], anchor, font.size, bold, NAME_OF[fill], s)
        return original_text(self, xy, s, fill, font, anchor, *a, **k)

    def wrap(name, describe):
        def method(self, *args, **kwargs):
            line(name, *describe(*args, **kwargs))
            return saved[name](self, *args, **kwargs)
        return method

    page.bar = wrap("bar", lambda x, y0, y1, name, w: (x, y0, y1, name, w))
    page.dot = wrap("dot", lambda cx, cy, r, name: (*box(cx, cy, r), name))
    page.disc = wrap("disc", lambda cx, cy, r, fill: (*box(cx, cy, r), NAME_OF[fill]))
    page.ring = wrap("ring", lambda cx, cy, r, colour, width=2: (*box(cx, cy, r), NAME_OF[colour], width))
    page.rect = wrap("rect", lambda x0, y0, x1, y1, fill=layouts.INK: (x0, y0, x1, y1, NAME_OF[fill]))
    page.line = wrap("line", lambda points, fill, width: (";".join(f"{x},{y}" for x, y in points), NAME_OF[fill], width))
    page.panel = wrap("panel", lambda x0, y0, x1, y1, name, radius: (x0, y0, x1, y1, name, radius))
    page.hairline_h = wrap("hairline_h", lambda x0, x1, y: (x0, x1, y))
    page.hairline_v = wrap("hairline_v", lambda x, y0, y1: (x, y0, y1))
    page.plus = wrap("plus", lambda px, dy, size: (px, dy, size))
    ImageDraw.ImageDraw.text = text
    try:
        render(*args)
    finally:
        for name, method in saved.items():
            setattr(page, name, method)
        ImageDraw.ImageDraw.text = original_text
    texts = layouts.drawn_texts(render, *args)
    assert [op.split("\t")[-1] for op in ops if op.startswith("text\t")] == texts
    return ops


def zone_of(name):
    if name[0] in "+-":
        sign = -1 if name[0] == "-" else 1
        h, m = name[1:].split(":")
        return timezone(sign * timedelta(hours=int(h), minutes=int(m)))
    return ZoneInfo(name)


def fixture(name):
    return AgendaData.from_json((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


TITLES = ["晨會", "產品設計審查：電子紙裝置同步功能", "Quarterly planning with the whole team", "會議 準備",
          "🎂🎉", "", "   ", "🎂 生日", "午餐", "Dentist", "讀完《原子習慣》", "x" * 60, "超長標題" * 75,
          "健身房", "家長會", "Call\twith\nBob", "咖啡日", "Café ☕ 聚會"]
PLACES = ["", "", "", "3F 大會議室", "鼎泰豐", "🏠", "Room 401, Building B, Long Street 123", "線上"]
COLOURS_IN = ["#f83a22", "#ff7537", "#fad165", "#16a765", "#4986e7", "#9a9cff", "#000000", "#cccccc", "",
              "#gggggg", "#7bd148", "#a47ae2"]


def random_agenda(today, zone):
    """A seeded agenda around ``today``: timed, all-day, multi-day, zero-length and midnight-crossing events."""
    events = []
    density = rng.choice([0, 1, 3, 6, 12, 24])
    for _ in range(density):
        day = today + timedelta(days=rng.randint(-3, 20) if rng.random() < 0.6 else rng.randint(-1, 1))
        title, place, colour = rng.choice(TITLES), rng.choice(PLACES), rng.choice(COLOURS_IN)
        if rng.random() < 0.25:
            events.append(Event(title, day, day + timedelta(days=rng.choice([1, 1, 2, 3, 9])), all_day=True,
                                location=place, color=colour))
            continue
        at = datetime.combine(day, time(rng.randint(0, 23), rng.choice([0, 15, 30, 45])), zone)
        at = at.astimezone(rng.choice([zone, timezone.utc, timezone(timedelta(hours=-5))]))
        length = rng.choice([timedelta(0), timedelta(minutes=30), timedelta(hours=1), timedelta(hours=2),
                             timedelta(hours=5), timedelta(hours=24), timedelta(hours=48), timedelta(hours=26)])
        if rng.random() < 0.1:  # exactly midnight to midnight
            at = datetime.combine(day, time(), zone)
            length = timedelta(days=rng.choice([1, 2]))
        events.append(Event(title, at, at + length, location=place, color=colour))
    fetched = None
    if rng.random() < 0.8:
        fetched = datetime.combine(today + timedelta(days=rng.choice([0, 0, 0, -1, -400])),
                                   time(rng.randint(0, 23), rng.randint(0, 59)), zone)
    return AgendaData(events=tuple(events), fetched_at=fetched)


def render_case(render, name, data, today, zone):
    """One render: ``data`` is a fixture name or an AgendaData."""
    source = data if isinstance(data, str) else data.to_json()
    agenda = fixture(data) if isinstance(data, str) else data
    ops = logged(render, agenda, today, zone_of(zone))
    return {"name": name, "data": source, "today": today.isoformat(), "zone": zone, "ops": ops}


def extreme_agenda():
    """test_layouts.test_extremes_do_not_break_the_pages."""
    data = fixture("sample")
    at = datetime(2026, 10, 12, 8, tzinfo=zone_of("+08:00"))
    long_title = "超長標題" * 75
    return AgendaData(events=data.events + (Event(long_title, at, at + timedelta(hours=1), color="#gggggg"),
                                            Event("", at, at, color="")),
                      tasks=data.tasks + tuple(Task(f"任務 {i}") for i in range(200)) + (Task(long_title),),
                      fetched_at=data.fetched_at)


def month_cases(render=layouts.render_month):
    cases = []

    def add(name, data, today, zone):
        cases.append(render_case(render, name, data, today, zone))

    for name in NAMES:
        for offset in (-6, -1, 0, 1, 5, 20):
            add(f"{name} {offset:+d}", name, date(2026, 10, 12) + timedelta(days=offset), "+08:00")
        for zone in ("-07:00", "America/New_York", "Pacific/Kiritimati"):
            add(f"{name} {zone}", name, date(2026, 10, 12), zone)
    for today in (date(2026, 2, 14), date(2026, 8, 20), date(2026, 8, 31), date(2026, 3, 1), date(2026, 12, 31),
                  date(2027, 1, 1), date(2015, 2, 1)):
        add(f"weeks {today}", "sample", today, "+08:00")
    # test_layouts.test_extremes_do_not_break_the_pages (the tasks do not change the month)
    extreme = extreme_agenda()
    add("extreme", AgendaData(events=extreme.events, fetched_at=extreme.fetched_at), date(2026, 10, 12), "+08:00")
    utc_late = datetime(2026, 10, 12, 17, 30, tzinfo=timezone.utc)
    other = AgendaData(events=(Event("深夜航班", utc_late, utc_late + timedelta(hours=2), color="#4986e7"),))
    for day in (12, 13):
        add(f"other zone {day}", other, date(2026, 10, day), "+08:00")
    # the US daylight saving change (2026-11-01 02:00 -> 01:00)
    ny = ZoneInfo("America/New_York")
    fold = AgendaData(events=(Event("重複的一小時", datetime(2026, 11, 1, 5, 30, tzinfo=timezone.utc),
                                    datetime(2026, 11, 1, 6, 30, tzinfo=timezone.utc), color="#16a765"),
                              Event("夜班", datetime(2026, 10, 31, 22, tzinfo=ny), datetime(2026, 11, 1, 3, tzinfo=ny),
                                    color="#f83a22")),
                      fetched_at=datetime(2026, 11, 1, 1, 30, fold=1, tzinfo=ny))
    for day in (31, 32):
        add(f"daylight saving {day}", fold, date(2026, 10, 31) + timedelta(days=day - 31), "America/New_York")
    zones = ["+08:00", "+00:00", "-07:00", "America/New_York", "Asia/Taipei", "+05:45"]
    for i in range(40):
        zone = rng.choice(zones)
        today = date(2026, 1, 1) + timedelta(days=rng.randint(0, 730))
        add(f"random {i}", random_agenda(today, zone_of(zone)), today, zone)
    return cases


def shifted(name, days):
    """A fixture moved ``days`` days later (events, tasks and the sync time)."""
    data, d = fixture(name), timedelta(days=days)
    return AgendaData(events=tuple(Event(e.title, e.start + d, e.end + d, e.all_day, e.calendar, e.location, e.color)
                                   for e in data.events),
                      tasks=tuple(Task(t.title, t.due + d if t.due else None, t.list_name, t.notes) for t in data.tasks),
                      fetched_at=data.fetched_at + d)


def agenda_cases():
    cases = []

    def add(name, data, today, zone):
        cases.append(render_case(layouts.render_agenda, name, data, today, zone))

    for name in NAMES:
        for offset in (-6, -1, 0, 1, 5, 20):
            add(f"{name} {offset:+d}", name, date(2026, 10, 12) + timedelta(days=offset), "+08:00")
        for zone in ("-07:00", "America/New_York", "Pacific/Kiritimati"):
            add(f"{name} {zone}", name, date(2026, 10, 12), zone)
    # "now" through the day: the hero is 進行中 or 接下來, ended events are counted
    tpe = zone_of("+08:00")
    for name in ("sample", "busy"):
        data = fixture(name)
        for hm in ((0, 0), (8, 30), (9, 15), (12, 0), (18, 0), (23, 59)):
            synced = AgendaData(events=data.events, fetched_at=datetime(2026, 10, 12, *hm, tzinfo=tpe))
            add(f"{name} synced {hm[0]:02d}:{hm[1]:02d}", synced, date(2026, 10, 12), "+08:00")
        add(f"{name} never synced", AgendaData(events=data.events), date(2026, 10, 12), "+08:00")
    for name in ("sample", "busy"):  # the week reaches into the new year (header with the year, 1月)
        add(f"{name} new year", shifted(name, 77), date(2026, 12, 28), "+08:00")
    extreme = extreme_agenda()
    add("extreme", AgendaData(events=extreme.events, fetched_at=extreme.fetched_at), date(2026, 10, 12), "+08:00")
    # test_layouts.test_events_in_other_time_zones_land_on_their_local_day
    utc_late = datetime(2026, 10, 12, 17, 30, tzinfo=timezone.utc)
    other = AgendaData(events=(Event("深夜航班", utc_late, utc_late + timedelta(hours=2), color="#4986e7"),))
    for day in (12, 13):
        add(f"other zone {day}", other, date(2026, 10, day), "+08:00")
    zones = ["+08:00", "+00:00", "-07:00", "America/New_York", "Asia/Taipei", "+05:45"]
    for i in range(40):
        zone = rng.choice(zones)
        today = date(2026, 1, 1) + timedelta(days=rng.randint(0, 730))
        add(f"random {i}", random_agenda(today, zone_of(zone)), today, zone)
    return cases


LISTS = ["", "", "我的任務", "家務", "工作", "🏠", "Shopping list with a rather long name"]
NOTES = ["", "", "", "記得帶發票", "🎉", "Bring the receipts and the signed form " * 3]


def random_tasks(today, n):
    """``n`` seeded tasks: overdue (also years ago), today, tomorrow, later (also next year), undated."""
    tasks = []
    for _ in range(n):
        due = None if rng.random() < 0.25 else today + timedelta(days=rng.choice(
            [-700, -30, -6, -2, -1, 0, 0, 1, 2, 6, 40, 400]))
        tasks.append(Task(rng.choice(TITLES), due, rng.choice(LISTS), rng.choice(NOTES)))
    return tuple(tasks)


def todo_cases():
    cases = []

    def add(name, data, today, zone="+08:00"):
        cases.append(render_case(layouts.render_todo, name, data, today, zone))

    for name in NAMES:
        for offset in (-6, -1, 0, 1, 5, 20):
            add(f"{name} {offset:+d}", name, date(2026, 10, 12) + timedelta(days=offset))
    today = date(2026, 10, 12)
    fetched = datetime(2026, 10, 12, 7, tzinfo=zone_of("+08:00"))
    for n in (1, 3, 5, 6, 7, 8, 10, 11, 14, 15, 16, 20, 33, 60, 201):  # each flat layout, then sections
        add(f"{n} tasks", AgendaData(tasks=random_tasks(today, n), fetched_at=fetched), today)
    # the year boundary: 逾期 649 天·2025年1月1日, 2027年3月1日
    year_end = date(2026, 12, 31)
    dated = (Task("付清貸款", date(2025, 1, 1)), Task("跨年煙火", year_end), Task("春季大掃除", date(2027, 3, 1)),
             Task("回診", date(2027, 1, 1)), Task("寫賀卡", date(2026, 12, 30)))
    add("year end", AgendaData(tasks=dated, fetched_at=fetched), year_end)
    add("year end sections", AgendaData(tasks=dated + random_tasks(year_end, 12)), year_end)
    add("extreme", extreme_agenda(), today)
    for i in range(40):
        today = date(2026, 1, 1) + timedelta(days=rng.randint(0, 730))
        n = rng.choice([0, 1, 3, 5, 7, 9, 12, 14, 15, 18, 25, 40, 100])
        fetched = datetime.combine(today + timedelta(days=rng.choice([0, -1, -400])), time(7), zone_of("+08:00"))
        add(f"random {i}", AgendaData(tasks=random_tasks(today, n), fetched_at=fetched), today,
            rng.choice(["+08:00", "America/New_York"]))
    return cases


def main():
    out = {"shapes": shape_cases(), "months": month_cases(), "agendas": agenda_cases(), "todos": todo_cases(),
           # the day and month grid pages over the month page's cases (added last: the random
           # agendas above stay as they were)
           "days": month_cases(layouts.render_day), "monthgrids": month_cases(layouts.render_monthgrid)}
    lines = ["{"]
    for n, (key, cases) in enumerate(out.items()):
        lines += [f' "{key}": [']
        lines += [f"  {json.dumps(c, ensure_ascii=False)}" + ("," if i < len(cases) - 1 else "")
                  for i, c in enumerate(cases)]
        lines += [" ]," if n < len(out) - 1 else " ]"]
    lines += ["}"]
    (HERE / "page-expectations.json").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
