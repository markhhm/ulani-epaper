"""Expected results for the Swift agenda model and notes store, computed with the Python reference.

Writes agenda-expectations.json next to this file. Run from the repository root with a Python
that has ulani_epaper installed (python/):

    python apple/UlaniKit/Tests/PaperhueAgendaTests/Differential/make_agenda_expectations.py

Zones are written as "+HH:MM" (a fixed offset) or an IANA name. For an IANA name the zone is
agenda.LOCAL with TZ set to that name, as the Windows app and the CLI see the computer's zone.
Events and tasks are referred to by their index in the input; days are ISO dates.
"""

import calendar
import json
import os
import tempfile
import time
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from ulani_epaper import notes
from ulani_epaper.agenda import LOCAL, AgendaData
from ulani_epaper.notes import Note

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]  # PaperhueAgendaTests, Tests, UlaniKit, apple, repository root
FIXTURES = REPO / "shared" / "layouts" / "agenda"
NAMES = ["sample", "empty", "busy", "midday"]
FIXTURE_ZONES = ["+08:00", "+00:00", "America/New_York", "Asia/Kolkata", "Pacific/Kiritimati", "America/Santiago"]
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


@contextmanager
def zone(name):
    """A fixed offset, or LOCAL with TZ=name for the duration."""
    if name[0] in "+-":
        sign = -1 if name[0] == "-" else 1
        h, m = name[1:].split(":")
        yield timezone(sign * timedelta(hours=int(h), minutes=int(m)))
        return
    saved = os.environ.get("TZ")
    os.environ["TZ"] = name
    time.tzset()
    try:
        yield LOCAL
    finally:
        if saved is None:
            del os.environ["TZ"]
        else:
            os.environ["TZ"] = saved
        time.tzset()


def days(first, last):
    d, end = date.fromisoformat(first), date.fromisoformat(last)
    while d <= end:
        yield d
        d += timedelta(days=1)


def micros(aware):
    """Microseconds since 1970 (exact integers, unlike timestamp())."""
    delta = aware - EPOCH
    return (delta.days * 86_400 + delta.seconds) * 1_000_000 + delta.microseconds


def events_on(data, zone_name, day_list):
    ids = {id(e): i for i, e in enumerate(data.events)}
    with zone(zone_name) as tz:
        return {d.isoformat(): [ids[id(e)] for e in data.events_on(d, tz)] for d in day_list}


def sorted_tasks(data):
    ids = {id(t): i for i, t in enumerate(data.tasks)}
    return [ids[id(t)] for t in data.sorted_tasks()]


def fixtures():
    out = {}
    for name in NAMES:
        data = AgendaData.from_json((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))
        out[name] = {
            "events_on": {z: events_on(data, z, list(days("2026-09-20", "2026-11-10"))) for z in FIXTURE_ZONES},
            "sorted_tasks": sorted_tasks(data),
            "to_json": data.to_json(),
        }
    return out


def ev(title, start, end, all_day=False):
    return {"title": title, "start": start, "end": end, "all_day": all_day}


def task(title, due=None):
    return {"title": title, "due": due}


CASES = [
    # New York falls back on 2026-11-01 at 06:00Z: 01:00-02:00 happens twice. Python compares
    # local wall-clock times (both sides have the page's tzinfo), so 01:15 EST sorts before 01:45 EDT.
    ("fold hour sorts by wall clock", "America/New_York", ("2026-10-31", "2026-11-02"), [
        ev("A 01:45 EDT", "2026-11-01T05:45:00+00:00", "2026-11-01T05:50:00+00:00"),
        ev("B 01:15 EST", "2026-11-01T06:15:00+00:00", "2026-11-01T06:20:00+00:00"),
        ev("C 00:30", "2026-11-01T04:30:00+00:00", "2026-11-01T04:40:00+00:00"),
    ], []),
    # One hour long, but 01:30 EDT -> 01:30 EST: the same wall time, so zero-length for Python.
    ("same wall start and end across the fold", "America/New_York", ("2026-10-31", "2026-11-02"), [
        ev("one hour", "2026-11-01T05:30:00+00:00", "2026-11-01T06:30:00+00:00"),
    ], []),
    # Titles compare as code points (no normalisation, no locale); equal keys keep input order.
    ("titles by code point", "+08:00", ("2026-10-12", "2026-10-12"), [
        ev("é", "2026-10-12", "2026-10-13", True),
        ev("f", "2026-10-12", "2026-10-13", True),
        ev("é", "2026-10-12", "2026-10-13", True),
        ev("Z", "2026-10-12", "2026-10-13", True),
        ev("a", "2026-10-12", "2026-10-13", True),
        ev("中", "2026-10-12", "2026-10-13", True),
        ev("\U0001F600", "2026-10-12", "2026-10-13", True),
        ev("Ａ", "2026-10-12", "2026-10-13", True),
        ev("same", "2026-10-12T09:00:00+08:00", "2026-10-12T10:00:00+08:00"),
        ev("same", "2026-10-12T09:00:00+08:00", "2026-10-12T09:30:00+08:00"),
        ev("Same", "2026-10-12T09:00:00+08:00", "2026-10-12T09:30:00+08:00"),
        ev("early", "2026-10-12T00:00:00+08:00", "2026-10-12T00:30:00+08:00"),
        ev("same instant, other offset", "2026-10-12T01:00:00Z", "2026-10-12T01:30:00Z"),
    ], []),
    ("zero-length, midnight and multi-day", "+08:00", ("2026-10-11", "2026-10-16"), [
        ev("at midnight", "2026-10-13T00:00:00+08:00", "2026-10-13T00:00:00+08:00"),
        ev("last second", "2026-10-12T23:59:59+08:00", "2026-10-12T23:59:59+08:00"),
        ev("ends at midnight", "2026-10-12T22:00:00+08:00", "2026-10-13T00:00:00+08:00"),
        ev("crosses midnight", "2026-10-12T22:00:00+08:00", "2026-10-13T02:00:00+08:00"),
        ev("three days", "2026-10-13T20:00:00+08:00", "2026-10-15T08:00:00+08:00"),
        ev("all-day zero", "2026-10-14", "2026-10-14", True),
        ev("all-day two", "2026-10-14", "2026-10-16", True),
        ev("backwards", "2026-10-15T10:00:00+08:00", "2026-10-15T09:00:00+08:00"),
        ev("utc offset", "2026-10-11T16:00:00Z", "2026-10-11T16:30:00Z"),
        ev("fraction", "2026-10-12T23:59:59.500000+08:00", "2026-10-13T00:00:00.250000+08:00"),
    ], []),
    # All-day events are local dates, whatever the zone's offset that day.
    ("all-day across a DST change", "America/New_York", ("2026-10-30", "2026-11-03"), [
        ev("weekend", "2026-10-31", "2026-11-02", True),
        ev("timed", "2026-11-01T12:00:00Z", "2026-11-01T13:00:00Z"),
    ], []),
    # Santiago skips 00:00-01:00 on 2026-09-06 (04:00Z) and repeats 23:00-24:00 on 2026-04-04.
    ("midnight fold", "America/Santiago", ("2026-04-03", "2026-04-06"), [
        ev("in the fold, first", "2026-04-05T02:30:00Z", "2026-04-05T02:45:00Z"),
        ev("in the fold, second", "2026-04-05T03:15:00Z", "2026-04-05T03:20:00Z"),
        ev("after", "2026-04-05T04:00:00Z", "2026-04-05T05:00:00Z"),
    ], []),
    ("midnight gap", "America/Santiago", ("2026-09-05", "2026-09-07"), [
        ev("over the gap", "2026-09-06T03:30:00Z", "2026-09-06T04:30:00Z"),
        ev("all-day", "2026-09-06", "2026-09-07", True),
    ], []),
    ("tasks", "+08:00", ("2026-10-12", "2026-10-12"), [], [
        task("undated b"), task("max", "9999-12-31"), task("min", "0001-01-01"),
        task("é", "2026-10-12"), task("é", "2026-10-12"), task("f", "2026-10-12"),
        task("undated a"), task("dup", "2026-10-11"), task("dup", "2026-10-11"), task("", None),
    ]),
]


def cases():
    out = []
    for name, zone_name, (first, last), events, tasks in CASES:
        text = json.dumps({"events": events, "tasks": tasks}, ensure_ascii=False)
        data = AgendaData.from_json(text)
        out.append({
            "name": name, "zone": zone_name, "data": text,
            "events_on": events_on(data, zone_name, list(days(first, last))),
            "sorted_tasks": sorted_tasks(data),
        })
    return out


# Python's to_json writes each value in its own offset; fractions only when non-zero.
TO_JSON_INPUT = json.dumps({
    "events": [
        {"title": "西半球", "start": "2026-10-12T09:00:00-03:30", "end": "2026-10-12T10:00-03:30", "all_day": False,
         "calendar": "工作", "location": "3F \"大\" 會議室\\A", "color": "#4986e7"},
        {"title": "UTC", "start": "2026-10-12T01:00:00Z", "end": "2026-10-12T01:00:00.000001+00:00"},
        {"title": "fraction", "start": "2026-10-12T09:00:00.5+05:45", "end": "2026-10-12T09:00:00.123456+05:45",
         "all_day": 1},
        {"title": "", "start": "2026-10-12", "end": "2026-10-13", "all_day": True, "location": "line\nbreak\ttab"},
    ],
    "tasks": [{"title": "繳費", "due": "2026-10-15", "list_name": "家務", "notes": "電費"}, {"title": "x", "due": ""}],
    "fetched_at": "2026-10-12T07:00:00.250000+08:00",
}, ensure_ascii=False)


def to_json():
    return {"input": TO_JSON_INPUT, "output": AgendaData.from_json(TO_JSON_INPUT).to_json(),
            "empty": AgendaData().to_json()}


# Wall time -> instant: zoneinfo (fold=0, what Foundation's Calendar does too) and LOCAL (the OS's
# mktime, which differs for times a change skips or repeats). "offset" is the zone's offset at
# the fold=0 instant.
WALLS = [
    ("America/New_York", ["2026-03-08T01:59:59", "2026-03-08T02:00:00", "2026-03-08T02:30:00",
                          "2026-03-08T03:00:00", "2026-11-01T00:59:59", "2026-11-01T01:00:00",
                          "2026-11-01T01:30:00", "2026-11-01T02:00:00", "2026-10-12T00:00:00"]),
    ("America/Santiago", ["2026-09-05T23:59:59", "2026-09-06T00:00:00", "2026-09-06T00:30:00",
                          "2026-09-06T01:00:00", "2026-04-04T22:59:59", "2026-04-04T23:00:00",
                          "2026-04-04T23:30:00", "2026-04-05T00:00:00"]),
    ("America/Havana", ["2026-03-08T00:00:00", "2026-03-08T00:30:00", "2026-03-08T01:00:00",
                        "2026-11-01T00:00:00", "2026-11-01T00:30:00", "2026-11-01T01:00:00"]),
    ("Asia/Beirut", ["2026-03-29T00:00:00", "2026-03-29T00:59:59", "2026-10-24T23:30:00",
                     "2026-10-25T00:00:00"]),
    ("Australia/Lord_Howe", ["2026-10-04T02:00:00", "2026-10-04T02:15:00", "2026-10-04T02:30:00",
                             "2026-04-05T01:30:00", "2026-04-05T01:45:00", "2026-04-05T02:00:00"]),
    ("Europe/London", ["2026-03-29T01:30:00", "2026-10-25T01:30:00", "2026-10-25T02:00:00"]),
    ("Asia/Taipei", ["2026-10-12T00:00:00", "1970-01-01T08:00:00"]),
    ("Asia/Kolkata", ["2026-10-12T00:00:00"]),
    ("UTC", ["2026-10-12T00:00:00", "1969-12-31T23:59:59"]),
]

# Instant -> wall time (astimezone) and the zone's offset at that instant. "local_offset" is what
# LOCAL.utcoffset() says for that wall time: for a repeated time it is the OS's guess, not always
# the offset of the instant.
INSTANTS = [
    ("America/New_York", ["2026-11-01T05:30:00Z", "2026-11-01T05:59:59Z", "2026-11-01T06:00:00Z",
                          "2026-11-01T06:30:00Z", "2026-03-08T06:59:59Z", "2026-03-08T07:00:00Z"]),
    ("America/Santiago", ["2026-09-06T03:59:59Z", "2026-09-06T04:00:00Z", "2026-04-05T02:30:00Z",
                          "2026-04-05T03:30:00Z"]),
    ("Australia/Lord_Howe", ["2026-10-03T15:29:59Z", "2026-10-03T15:30:00Z", "2026-04-04T14:30:00Z",
                             "2026-04-04T15:00:00Z"]),
    ("Asia/Kolkata", ["2026-10-11T18:30:00Z", "2026-10-11T18:29:59Z"]),
    ("Pacific/Kiritimati", ["2026-10-12T09:59:59Z", "2026-10-12T10:00:00Z"]),
    ("+08:00", ["2026-10-11T16:00:00Z", "1969-12-31T23:59:59.500000Z"]),
]


def walls():
    out = []
    for zone_name, items in WALLS:
        for text in items:
            naive = datetime.fromisoformat(text)
            fold0 = naive.replace(tzinfo=ZoneInfo(zone_name))
            with zone(zone_name) as tz:
                local = naive.replace(tzinfo=tz)
                local_micros = micros(local)
            offset = fold0.astimezone(timezone.utc).astimezone(ZoneInfo(zone_name)).utcoffset()
            out.append({"zone": zone_name, "wall": text, "fold0": micros(fold0),
                        "offset": int(offset.total_seconds()), "local": local_micros})
    return out


def instants():
    out = []
    for zone_name, items in INSTANTS:
        for text in items:
            utc = datetime.fromisoformat(text)
            with zone(zone_name) as tz:
                local = utc.astimezone(tz)
                wall, local_offset = local.replace(tzinfo=None).isoformat(), local.utcoffset()
            offset = local_offset
            if zone_name[0] not in "+-":
                exact = utc.astimezone(ZoneInfo(zone_name))
                assert exact.replace(tzinfo=None).isoformat() == wall
                offset = exact.utcoffset()
            out.append({"zone": zone_name, "instant": text, "micros": micros(utc), "wall": wall,
                        "offset": int(offset.total_seconds()), "local_offset": int(local_offset.total_seconds())})
    return out


DATES = ["0001-01-01", "0001-12-31", "0004-02-29", "1582-10-04", "1582-10-15", "1899-12-31", "1900-02-28",
         "1900-03-01", "1969-12-31", "1970-01-01", "2000-02-29", "2026-10-12", "2026-12-31", "2027-01-01",
         "2100-03-01", "9999-12-31"]


def dates():
    return [{"iso": text, "ordinal": date.fromisoformat(text).toordinal(),
             "weekday": date.fromisoformat(text).weekday()} for text in DATES]


def months():
    out = []
    for first_weekday in (6, 0):
        cal = calendar.Calendar(firstweekday=first_weekday)
        for year in (1900, 2000, 2026, 2027, 2028, 2100):
            for month in range(1, 13):
                weeks = cal.monthdatescalendar(year, month)
                assert all(len(w) == 7 for w in weeks)
                out.append({"year": year, "month": month, "first_weekday": first_weekday,
                            "first": weeks[0][0].isoformat(), "weeks": len(weeks)})
    return out


ISO_TEXTS = [
    # what isoformat() writes
    "2026-10-12T14:03:00+08:00", "2026-10-12T14:03:00-03:30", "2026-10-12T14:03:00+00:00",
    "2026-10-12T14:03:00.500000+08:00", "2026-10-12T14:03:00.000001+08:00", "2026-10-12T14:03:00+05:44:30",
    "0001-01-01T00:00:00+00:00", "9999-12-31T23:59:59.999999+00:00",
    # shorter and other accepted forms
    "2026-10-12T14:03+08:00", "2026-10-12T14+08:00", "2026-10-12T14:03:00Z", "2026-10-12 14:03:00+08:00",
    "2026-10-12T14:03:00.5+08:00", "2026-10-12T14:03:00.1234567+08:00", "2026-10-12T14:03:00,5+08:00",
    "2026-10-12T14:03:00.1234+08:00", "2026-10-12T14:03:00+08", "2026-10-12T14:03:00+0800",
    "2026-10-12T14:03:00-00:00", "2026-10-12T14:03:00+083000",
    # no offset
    "2026-10-12T14:03:00", "2026-10-12T14:03", "2026-10-12T14:03:00.25",
    # refused by Python
    "2026-10-12T14:03:00z", "2026-10-12T14:03:00+24:00", "2026-10-12T25:00:00+08:00", "2026-02-30T14:03:00+08:00",
    "2026-10-12T14:60:00+08:00", "2026-10-12T14:03:61+08:00", "2026-10-12T", "yesterday", "", "2026-10-12T9:00+08:00",
    "2026-10-12T14:03:00+8:00", "2026-10-12T14:03:00+08:00 ", " 2026-10-12T14:03:00+08:00", "２０２６-10-12T14:03:00+08:00",
    "+2026-10-12T14:03:00+08:00",
]

# Python accepts these too; the Swift reader refuses them (week dates, basic format, 24:00,
# odd separators, a space, a fraction or 60 minutes/seconds in the offset). Nothing Paperhue
# writes looks like this.
ISO_REFUSED_BY_SWIFT = [
    "2026-W41-1T10:00+08:00", "20261012T140300+0800", "2026-10-12T24:00:00+08:00", "2026-10-12x14:03:00+08:00",
    "2026-10-12T14:03:00 +08:00", "2026-10-12T14:03:00.+08:00", "2026-10-12T14:03:00+08:00:30.5",
    "2026-10-12T1403+08:00", "2026-10-12T14:03:00+08:60", "2026-10-12T14:03:00+08:00:60",
]
DATES_REFUSED_BY_SWIFT = ["20261012", "2026-W41-1"]


def iso():
    out = []
    for text in ISO_TEXTS + ISO_REFUSED_BY_SWIFT:
        entry = {"text": text, "swift_refuses": text in ISO_REFUSED_BY_SWIFT}
        try:
            value = datetime.fromisoformat(text)
        except ValueError:
            entry["ok"] = False
        else:
            entry["ok"] = True
            entry["wall"] = value.replace(tzinfo=None).isoformat()
            offset = value.utcoffset()
            entry["offset"] = None if offset is None else int(offset.total_seconds())
            entry["micros"] = None if offset is None else micros(value)
            entry["isoformat"] = value.isoformat()
        out.append(entry)
    for text in ["2026-10-12", "0001-01-01", "2024-02-29", "2026-02-29", "2026-10-1", "2026-13-01", "", *DATES_REFUSED_BY_SWIFT]:
        entry = {"text": text, "swift_refuses": text in DATES_REFUSED_BY_SWIFT}
        try:
            entry["date"] = date.fromisoformat(text).isoformat()
        except ValueError:
            entry["date"] = None
        out.append(entry)
    return out


TEXTS = [
    "", " \n\t ", "字" * 300, "字" * 301, "\n".join("一二三四五六七八"), "\n".join("一二三四五六七八九"),
    "e\N{COMBINING ACUTE ACCENT}" * 300, "  " + "e\N{COMBINING ACUTE ACCENT}" * 300 + "  ", " a\r\nb ",
    "a\rb\r\nc\n\rd", "\x1c a \x1f", "\N{IDEOGRAPHIC SPACE}全形空白\N{IDEOGRAPHIC SPACE}", "a\x85", "\x85a\xa0",
    "\N{ZERO WIDTH SPACE}零寬\N{ZERO WIDTH SPACE}", "\N{ZERO WIDTH NO-BREAK SPACE}BOM",
    "\N{LINE SEPARATOR}a\N{PARAGRAPH SEPARATOR}", " \N{COMBINING ACUTE ACCENT}", "x\N{COMBINING ACUTE ACCENT} ",
    "\N{HEAVY BLACK HEART}\N{VARIATION SELECTOR-16}" * 150, "\N{HEAVY BLACK HEART}\N{VARIATION SELECTOR-16}" * 151,
    "\U0001F468\N{ZERO WIDTH JOINER}\U0001F469\N{ZERO WIDTH JOINER}\U0001F467", "晚餐在冰箱",
    "  我去接小孩\r\n六點前回來  ", "\n\n\n\n\n\n\n\n\nx", "x\n\n\n\n\n\n\n", "x\n\n\n\n\n\n\n\n", "\t\v\f",
    "\N{OGHAM SPACE MARK}\N{EN QUAD}\N{HAIR SPACE}\N{NARROW NO-BREAK SPACE}\N{MEDIUM MATHEMATICAL SPACE}",
    "\N{LATIN CAPITAL LETTER A WITH RING ABOVE}", "\N{ANGSTROM SIGN}",
    "\N{HALFWIDTH KATAKANA LETTER KA}\N{HALFWIDTH KATAKANA VOICED SOUND MARK}",
    "\N{HANGUL CHOSEONG KIYEOK}\N{HANGUL JUNGSEONG A}\N{HANGUL JONGSEONG KIYEOK}",
]


def texts():
    out = []
    for text in TEXTS:
        entry = {"text": text, "normalized": notes.normalize(text)}
        try:
            entry["checked"] = notes.check_text(text)
        except ValueError as e:
            entry["error"] = str(e)
        out.append(entry)
    return out


FILE_NOTES = [
    Note("a1b2c3d4", "晚餐在冰箱，微波 3 分鐘就好", "2026-10-12T14:03:00+08:00", "yellow"),
    Note("0f1e2d3c", "引號 \" 反斜線 \\ 斜線 / tab\there\n第二行", "2026-10-12T06:30:00+00:00", "blue"),
    Note("deadbeef", "控制字元 \x01\x1f\x7f 與 \N{LINE SEPARATOR} \N{PARAGRAPH SEPARATOR} \U0001F382 \xe9",
         "2026-10-11T21:40:00-03:30", "red"),
]


def notes_files():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "notes.json"
        notes.save(FILE_NOTES, path)
        full = path.read_text(encoding="utf-8")
        notes.save([], path)
        empty = path.read_text(encoding="utf-8")
    return {"notes": [n.__dict__ for n in FILE_NOTES], "file": full, "empty_file": empty,
            "colours": list(notes.NOTE_COLOURS), "max_notes": notes.MAX_NOTES, "max_text": notes.MAX_TEXT,
            "max_lines": notes.MAX_LINES}


def main():
    out = {
        "generated_by": "apple/UlaniKit/Tests/PaperhueAgendaTests/Differential/make_agenda_expectations.py",
        "fixtures": fixtures(),
        "cases": cases(),
        "to_json": to_json(),
        "walls": walls(),
        "instants": instants(),
        "dates": dates(),
        "months": months(),
        "iso": iso(),
        "whitespace": [c for c in range(0x110000) if chr(c).isspace()],
        "texts": texts(),
        "notes_files": notes_files(),
    }
    text = json.dumps(out, ensure_ascii=True, indent=1, sort_keys=True) + "\n"
    (HERE / "agenda-expectations.json").write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
