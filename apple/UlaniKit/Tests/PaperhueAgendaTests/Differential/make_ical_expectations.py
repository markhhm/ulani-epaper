"""Write ical-expectations.json: how the Python reference reads iCalendar data (the reading half
of python/src/ulani_epaper/ical.py: icalendar.use_zoneinfo(), Calendar.from_ical, the
VCALENDAR check), for ICalReadingTests.swift.

- "reading": small calendars plus shared/vectors/ical/*.ics. For each component (walk order),
  the properties ical.py reads, as text or as decoded date/time values; null = not a calendar.
- "zones": UTC offsets of wall times (fold=0) and wall times of UTC instants around DST changes,
  for IANA zones and for VTIMEZONE definitions as real feeds send them.
- "differences": Python's `b - a` for aware datetimes (same zone: wall clock; else instants).

Run with the reference environment: python make_ical_expectations.py
"""

import json
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import icalendar
from icalendar.prop import vBroken

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
FIXTURES = ["shared/vectors/ical/google.ics", "shared/vectors/ical/outlook.ics", "shared/vectors/ical/todos.ics"]

TEXT = {"SUMMARY", "LOCATION", "DESCRIPTION", "UID", "STATUS", "ATTENDEE", "PERCENT-COMPLETE", "TZID",
        "X-WR-CALNAME", "X-WR-TIMEZONE"}
DATES = {"DTSTART", "DTEND", "DUE", "RECURRENCE-ID", "DURATION", "RDATE", "EXDATE"}


def cal(*lines: str) -> str:
    return "BEGIN:VCALENDAR\r\n" + "".join(x + "\r\n" for x in lines) + "END:VCALENDAR\r\n"


def zone(tzid: str, *observances: tuple[str, str, str, str, list[str]]) -> list[str]:
    """A VTIMEZONE: observances are (kind, DTSTART, from, to, more lines)."""
    lines = ["BEGIN:VTIMEZONE", "TZID:" + tzid]
    for kind, start, offset_from, offset_to, more in observances:
        lines += [f"BEGIN:{kind}", "DTSTART:" + start, *more, "TZOFFSETFROM:" + offset_from,
                  "TZOFFSETTO:" + offset_to, f"END:{kind}"]
    return lines + ["END:VTIMEZONE"]


def fixed(tzid: str, offset: str) -> list[str]:
    return zone(tzid, ("STANDARD", "19700101T000000", offset, offset, []))


def uses(tzid: str) -> list[str]:
    return ["BEGIN:VEVENT", "UID:z", f"DTSTART;TZID={tzid}:20261012T090000", "END:VEVENT"]


READING = {
    "lines": "﻿" + cal(
        "X-WR-CALNAME:個", " 人", "BEGIN:VEVENT", "summary:fold with", "\ta tab and", "  two spaces",
        "DESCRIPTION:folded after", "", " a blank line", "Location ;LANGUAGE = zh :  台北 ",
        "DTSTART;VALUE=DATE:20261012", "END:VEVENT"),
    "lf-only": cal("BEGIN:VEVENT", "SUMMARY:line feeds", " only", "DTSTART:20261012T010000Z", "END:VEVENT")
    .replace("\r\n", "\n"),
    "parameters": cal(
        "BEGIN:VEVENT",
        'ATTENDEE;CN="Doe, John";PARTSTAT=DECLINED;MEMBER="mailto:a@x.org","mailto:b@x.org":mailto:me@x.org',
        "ATTENDEE;CN=Doe\\, Jane;partstat=accepted:mailto:jane@x.org",
        "ATTENDEE;X-SAY=\"^'hi^' ^^ ^n\";ROLE=CHAIR:mailto:chair@x.org",
        'LOCATION;ALTREP="http://x.org/a;b:c":Room 1', "END:VEVENT"),
    "text": cal(
        "X-WR-CALNAME:Work\\, home", "X-WR-TIMEZONE:Asia/Taipei", "BEGIN:VEVENT",
        "SUMMARY:a\\,b\\;c\\nd\\Ne\\\\f\\:g\\xh", "DESCRIPTION:first\\n\\nsecond", "UID:1@x", "STATUS:confirmed",
        "END:VEVENT"),
    "values": cal(
        "BEGIN:VEVENT", "DTSTART;VALUE=DATE:20261012", "DTEND;VALUE=DATE:20261013", "DUE:20261012T150000Z",
        "RECURRENCE-ID;TZID=Asia/Taipei:20261012T090000", "DURATION:P1W", "END:VEVENT",
        "BEGIN:VEVENT", "DTSTART:20261012T090000", "DURATION:-PT15M", "END:VEVENT",
        "BEGIN:VEVENT", "DTSTART;TZID=Unknown/Zone:20261012T090000", "DTEND;TZID=Unknown/Zone:20261012T100000Z",
        "DURATION:P1DT2H3M4S", "END:VEVENT",
        "BEGIN:VEVENT", "DTSTART;TZID=Asia/Taipei;VALUE=DATE:20261012", "DTEND;TZID=:20261012T090000",
        "DUE;TZID=Asia/Taipei:20261012T090000Z", "DURATION:P", "END:VEVENT",
        "BEGIN:VEVENT", "DTSTART;TZID=Taipei Standard Time:20261013T140000",
        "DTEND;TZID=/freeassociation.sourceforge.net/Europe/Berlin:20261013T080000",
        "DUE;TZID=/Asia/Taipei/:20261013T080000", "DURATION:PT0S", "END:VEVENT",
        "BEGIN:VEVENT", "DTSTART:20261020T010000Z", "RDATE:20261020T010000Z,20261027T010000Z",
        "RDATE;VALUE=DATE:20261101,20261102", "RDATE;VALUE=PERIOD:20261020T010000Z/PT1H", "RDATE:",
        "EXDATE;TZID=Europe/Berlin:20261020T030000,20261027T030000", "EXDATE;VALUE=DATE:20261103",
        "END:VEVENT"),
    "broken-event": cal(
        "BEGIN:VEVENT", "SUMMARY:still read", "THIS IS NOT A CONTENT LINE", "DTSTART:2026-10-12",
        "DTEND:20261012T250000", "DURATION:1H", "RDATE:20261012T0900", "END:VEVENT",
        "BEGIN:VTODO", "SUMMARY:fine", "DUE;VALUE=DATE:20261012", "END:VTODO"),
    "x-comment-after-the-end": cal("BEGIN:VEVENT", "SUMMARY:x", "END:VEVENT") + "X-COMMENT:after\r\n",
    "forward-reference": cal(*uses("Custom/Later"), *fixed("Custom/Later", "+0530")),
    "windows-name-defined-first": cal(*fixed("Taipei Standard Time", "+0900"), *uses("Taipei Standard Time")),
    "windows-name-defined-after": cal(*uses("Taipei Standard Time"), *fixed("Taipei Standard Time", "+0900")),
    "iana-name-defined": cal(*fixed("Asia/Taipei", "+0100"), *uses("Asia/Taipei")),
    "same-tzid-twice": cal(*fixed("Custom/Twice", "+0100"), *fixed("Custom/Twice", "+0200"), *uses("Custom/Twice")),
    "x-properties-in-vtimezone": cal(
        "BEGIN:VTIMEZONE", "TZID:Custom/X", "X-LIC-LOCATION:Somewhere", "BEGIN:STANDARD",
        "DTSTART;VALUE=DATE:19700101", "TZOFFSETFROM:+0300", "TZOFFSETTO:+0300", "TZNAME:XT", "END:STANDARD",
        "END:VTIMEZONE", *uses("Custom/X")),
    # not a calendar (ical.ICalError)
    "empty": "",
    "html": "<html>not a calendar</html>",
    "vcard": "BEGIN:VCARD\r\nEND:VCARD\r\n",
    "bad-line-outside-an-event": cal("NOT A CONTENT LINE"),
    "bad-due-in-a-todo": cal("BEGIN:VTODO", "DUE:2026-10-12", "END:VTODO"),
    "two-calendars": cal() + cal(),
    "end-without-begin": "END:VEVENT\r\n" + cal(),
    "property-after-the-end": cal() + "SUMMARY:x\r\n",
    "never-closed": "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n",
    "broken-vtimezone": cal("BEGIN:VTIMEZONE", "TZID:Custom/Broken", "BEGIN:STANDARD", "DTSTART:19700101T000000",
                            "TZOFFSETTO:+0100", "END:STANDARD", "END:VTIMEZONE"),
}

US_RULES = [("STANDARD", "19701101T020000", "-0400", "-0500", ["RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"]),
            ("DAYLIGHT", "19700308T020000", "-0500", "-0400", ["RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU"])]
CUSTOM = {
    # as outlook.ics (Outlook / Exchange)
    "Custom/Eastern": zone("Custom/Eastern", *US_RULES),
    # as iCloud and Nextcloud write a zone's history: rules that end (UNTIL) and their successors
    "Custom/NY-history": zone(
        "Custom/NY-history",
        ("DAYLIGHT", "19870405T020000", "-0500", "-0400", ["RRULE:FREQ=YEARLY;BYMONTH=4;BYDAY=1SU;UNTIL=20060402T070000Z"]),
        ("STANDARD", "19671029T020000", "-0400", "-0500", ["RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU;UNTIL=20061029T060000Z"]),
        ("DAYLIGHT", "20070311T020000", "-0500", "-0400", ["RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU"]),
        ("STANDARD", "20071104T020000", "-0400", "-0500", ["RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"])),
    # Outlook's southern hemisphere zones: onsets since 1601
    "Custom/Sydney": zone(
        "Custom/Sydney",
        ("STANDARD", "16010101T030000", "+1100", "+1000", ["RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4"]),
        ("DAYLIGHT", "16010101T020000", "+1000", "+1100", ["RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10"])),
    # onsets listed one by one (RDATE), and a rule with COUNT
    "Custom/Listed": zone(
        "Custom/Listed",
        ("DAYLIGHT", "20260329T020000", "+0100", "+0200", ["RDATE:20270328T020000"]),
        ("STANDARD", "20261025T030000", "+0200", "+0100", ["RDATE:20271031T030000,20281029T030000"])),
    "Custom/Counted": zone(
        "Custom/Counted",
        ("DAYLIGHT", "20200308T020000", "-0500", "-0400", ["RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU;COUNT=3"]),
        ("STANDARD", "20201101T020000", "-0400", "-0500", ["RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"])),
}

US_WALLS = ["2026-03-08T01:30:00", "2026-03-08T02:30:00", "2026-03-08T03:30:00", "2026-11-01T00:30:00",
            "2026-11-01T01:30:00", "2026-11-01T02:30:00", "2026-07-01T12:00:00"]
US_UTC = ["2026-03-08T06:30:00", "2026-03-08T07:30:00", "2026-11-01T05:30:00", "2026-11-01T06:30:00"]
ZONE_CHECKS = {
    "America/New_York": (US_WALLS, US_UTC),
    "Europe/Berlin": (["2026-03-29T02:30:00", "2026-10-25T02:30:00", "2026-10-25T03:30:00"],
                      ["2026-10-25T00:30:00", "2026-10-25T01:30:00"]),
    "Australia/Lord_Howe": (["2026-04-05T01:45:00", "2026-10-04T02:15:00", "2026-07-01T12:00:00"],
                            ["2026-04-04T14:45:00", "2026-04-04T15:15:00"]),
    "Custom/Eastern": (US_WALLS, US_UTC),
    "Custom/NY-history": (["1960-01-01T00:00:00", "1990-07-01T12:00:00", "2005-04-03T01:30:00",
                           "2005-04-03T02:30:00", "2005-10-30T01:30:00", "2006-07-01T12:00:00",
                           "2007-03-11T02:30:00", "2026-03-08T02:30:00", "2026-11-01T01:30:00"],
                          ["2005-10-30T05:30:00", "2026-07-01T12:00:00"]),
    "Custom/Sydney": (["2026-01-15T12:00:00", "2026-04-05T02:30:00", "2026-04-05T03:30:00",
                       "2026-07-15T12:00:00", "2026-10-04T02:30:00"],
                      ["2026-04-04T15:30:00", "2026-04-04T16:30:00", "2026-07-15T00:00:00"]),
    "Custom/Listed": (["2026-01-01T12:00:00", "2026-06-01T12:00:00", "2026-12-01T12:00:00",
                       "2027-06-01T12:00:00", "2027-12-01T12:00:00", "2028-12-01T12:00:00"],
                      ["2026-06-01T12:00:00"]),
    "Custom/Counted": (["2020-06-01T12:00:00", "2022-06-01T12:00:00", "2023-06-01T12:00:00",
                        "2026-01-01T12:00:00"], []),
}

DIFFERENCES = [  # (zone a, wall a, zone b, wall b)
    ("America/New_York", "2026-03-08T01:00:00", "America/New_York", "2026-03-08T04:00:00"),
    ("America/New_York", "2026-11-01T00:30:00", "America/New_York", "2026-11-01T02:30:00"),
    ("America/New_York", "2026-03-08T01:00:00", "UTC", "2026-03-08T09:00:00"),
    ("Custom/Eastern", "2026-11-01T00:30:00", "Custom/Eastern", "2026-11-01T02:30:00"),
    ("Custom/Eastern", "2026-11-01T00:30:00", "America/New_York", "2026-11-01T02:30:00"),
]


def read(data: bytes):
    """The calendar as ical.parse reads it, or None for ICalError."""
    icalendar.use_zoneinfo()
    try:
        calendar = icalendar.Calendar.from_ical(data)
    except Exception:
        return None
    return calendar if getattr(calendar, "name", "") == "VCALENDAR" else None


def when(value) -> str:
    if isinstance(value, tuple):
        return "period"
    if isinstance(value, timedelta):
        return f"duration {value // timedelta(seconds=1)}"
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return "floating " + value.isoformat()
        return f"{value.isoformat()} ({value.astimezone(timezone.utc):%Y-%m-%dT%H:%M:%SZ})"
    if isinstance(value, date):
        return "date " + value.isoformat()
    return type(value).__name__


def show(name: str, value) -> str:
    params = ";".join(f"{k}={','.join(v) if isinstance(v, list) else v}" for k, v in sorted(value.params.items()))
    head = name + (";" + params if params else "")
    if isinstance(value, vBroken):
        return head + " broken"
    if name in DATES:
        values = [d.dt for d in value.dts] if name in ("RDATE", "EXDATE") else [value.dt]
        return head + " " + ", ".join(when(v) for v in values)
    return head + ":" + str(value)


def describe(calendar) -> list:
    out = []
    for comp in calendar.walk():
        lines = []
        for name in sorted(comp.keys()):
            if name in TEXT or name in DATES:
                values = comp[name] if isinstance(comp[name], list) else [comp[name]]
                lines += [show(name, v) for v in values]
        out.append([comp.name, lines])
    return out


def tzinfo(name: str):
    if name not in CUSTOM:
        return ZoneInfo(name)
    calendar = read(cal(*CUSTOM[name], *uses(name)).encode())
    return calendar.walk("VEVENT")[0]["DTSTART"].dt.tzinfo


def main() -> None:
    reading = []
    for name, text in READING.items():
        calendar = read(text.encode())
        reading.append({"name": name, "ics": text, "components": describe(calendar) if calendar else None})
    for path in FIXTURES:
        calendar = read((REPO / path).read_bytes())
        reading.append({"name": path, "file": path, "components": describe(calendar)})

    zones = []
    for name, (walls, instants) in ZONE_CHECKS.items():
        tz = tzinfo(name)
        offsets = [[w, datetime.fromisoformat(w).replace(tzinfo=tz).utcoffset() // timedelta(seconds=1)]
                   for w in walls]
        clock = [[u, datetime.fromisoformat(u).replace(tzinfo=timezone.utc).astimezone(tz).replace(tzinfo=None)
                  .isoformat()] for u in instants]
        zones.append({"zone": name, "vtimezone": "\r\n".join(CUSTOM.get(name, [])), "offsets": offsets,
                      "wall_clock": clock})

    differences = []
    for za, a, zb, b in DIFFERENCES:
        ta = tzinfo(za)
        tb = ta if zb == za else tzinfo(zb)  # one TZID in one feed is one tzinfo object
        seconds = (datetime.fromisoformat(b).replace(tzinfo=tb) - datetime.fromisoformat(a).replace(tzinfo=ta))
        differences.append([za, a, zb, b, seconds // timedelta(seconds=1)])

    out = {"icalendar": icalendar.__version__, "reading": reading, "zones": zones, "differences": differences}
    (HERE / "ical-expectations.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n",
                                                 encoding="utf-8")
    print(f"{len(reading)} calendars, {sum(len(z['offsets']) + len(z['wall_clock']) for z in zones)} zone checks, "
          f"{len(differences)} differences")


if __name__ == "__main__":
    main()
