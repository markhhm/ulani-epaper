"""Write parse-expectations.json: what the Python reference's ical.parse makes of whole calendars,
for ICalParseTests.swift.

- "files": shared/vectors/ical/*.ics read in a zone with daylight saving time, with a feed name
  and colour (shared/vectors/ical-vectors.json has them in UTC+8 without).
- "rules": recurring events against dateutil's rrule (through ical.parse, so DTSTART, UNTIL,
  RDATE and EXDATE are converted as ical.py converts them), plus the limits.

Only rules the Swift side expands are listed (no SECONDLY/MINUTELY/HOURLY, BYWEEKNO, BYYEARDAY,
BYHOUR/BYMINUTE/BYSECOND; apple/DEVELOPING.md). Run from the repository root with a Python that
has ulani_epaper installed (python/):

    python apple/UlaniKit/Tests/PaperhueAgendaTests/Differential/make_parse_expectations.py
"""

import json
from datetime import date, datetime, time
from pathlib import Path
from zoneinfo import ZoneInfo

from ulani_epaper import ical

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
TPE = "Asia/Taipei"
NYC = "America/New_York"
WIDE = ("2026-01-01", "2028-01-01")


def cal(*lines: str) -> str:
    return "BEGIN:VCALENDAR\r\n" + "".join(x + "\r\n" for x in lines) + "END:VCALENDAR\r\n"


def event(start: str, *lines: str, uid: str = "u", summary: str = "x") -> list[str]:
    return ["BEGIN:VEVENT", "UID:" + uid, "SUMMARY:" + summary, start, *lines, "END:VEVENT"]


def tpe(wall: str) -> str:
    return "DTSTART;TZID=Asia/Taipei:" + wall


def nyc(wall: str) -> str:
    return "DTSTART;TZID=America/New_York:" + wall


CET = ["BEGIN:VTIMEZONE", "TZID:W. Europe Custom", "BEGIN:STANDARD", "DTSTART:16011028T030000",
       "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "END:STANDARD",
       "BEGIN:DAYLIGHT", "DTSTART:16010325T020000", "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3",
       "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200", "END:DAYLIGHT", "END:VTIMEZONE"]

# name -> (page zone, [first, last) window as dates, calendar)
RULES = {
    "daily, interval and count across a DST change":
        (NYC, ("2027-03-01", "2027-04-01"),
         cal(*event(nyc("20270310T090000"), "DURATION:PT1H", "RRULE:FREQ=DAILY;INTERVAL=3;COUNT=10"))),
    "weekly on three days until a UTC time":
        (TPE, WIDE, cal(*event(tpe("20261005T090000"), "DTEND;TZID=Asia/Taipei:20261005T093000",
                               "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261231T235959Z"))),
    "every other week, weeks from Monday":
        (TPE, WIDE, cal(*event(tpe("20261013T090000"), "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=6;BYDAY=TU,SU;WKST=MO"))),
    "every other week, weeks from Sunday":
        (TPE, WIDE, cal(*event(tpe("20261013T090000"), "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=6;BYDAY=TU,SU;WKST=SU"))),
    "first of a partial week":
        (TPE, WIDE, cal(*event(tpe("20261014T090000"), "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;BYSETPOS=1;COUNT=4"))),
    "monthly on the last Friday":
        (TPE, WIDE, cal(*event(tpe("20260130T190000"), "RRULE:FREQ=MONTHLY;BYDAY=-1FR"))),
    "monthly on the second Tuesday, six times":
        (TPE, WIDE, cal(*event(tpe("20260113T120000"), "RRULE:FREQ=MONTHLY;BYDAY=2TU;COUNT=6"))),
    "monthly on the fifth Friday":
        (TPE, WIDE, cal(*event(tpe("20260130T090000"), "RRULE:FREQ=MONTHLY;BYDAY=5FR"))),
    "monthly on the last day, all day":
        (TPE, WIDE, cal(*event("DTSTART;VALUE=DATE:20260131", "RRULE:FREQ=MONTHLY;BYMONTHDAY=-1"))),
    "monthly on the 31st":
        (TPE, WIDE, cal(*event(tpe("20260131T080000"), "RRULE:FREQ=MONTHLY"))),
    "monthly on the last weekday":
        (TPE, WIDE, cal(*event(tpe("20260130T170000"), "RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"))),
    "monthly on the first and last weekend day":
        (TPE, WIDE, cal(*event(tpe("20260103T100000"), "RRULE:FREQ=MONTHLY;BYDAY=SA,SU;BYSETPOS=1,-1;COUNT=10"))),
    "every other month on the first and last day":
        (TPE, WIDE, cal(*event(tpe("20260101T090000"), "RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=1,-1;COUNT=8"))),
    "yearly on a leap day":
        (TPE, ("2026-01-01", "2034-01-01"), cal(*event("DTSTART;VALUE=DATE:20240229", "RRULE:FREQ=YEARLY"))),
    "yearly on the last Sunday of March, at a time that does not exist":
        (TPE, ("2026-01-01", "2031-01-01"),
         cal(*event("DTSTART;TZID=Europe/Berlin:20250330T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU"))),
    "yearly on the 20th Monday":
        (TPE, ("2026-01-01", "2030-01-01"), cal(*event(tpe("20260101T090000"), "RRULE:FREQ=YEARLY;BYDAY=20MO"))),
    "yearly on the last Monday, three times":
        (TPE, ("2026-01-01", "2030-01-01"),
         cal(*event(tpe("20260101T090000"), "RRULE:FREQ=YEARLY;BYDAY=-1MO;COUNT=3"))),
    "yearly in two months on two days":
        (TPE, WIDE, cal(*event(tpe("20260101T090000"), "RRULE:FREQ=YEARLY;BYMONTH=1,7;BYMONTHDAY=1,15"))),
    "daily on December weekends":
        (TPE, WIDE, cal(*event(tpe("20261201T090000"), "RRULE:FREQ=DAILY;BYMONTH=12;BYDAY=SA,SU"))),
    "weekly until a date, New York":
        (NYC, ("2026-10-01", "2027-01-01"),
         cal(*event(nyc("20261006T200000"), "DURATION:PT1H", "RRULE:FREQ=WEEKLY;UNTIL=20261110"))),
    "floating times until a UTC time":
        (TPE, ("2026-10-01", "2027-01-01"),
         cal("X-WR-TIMEZONE:America/New_York",
             *event("DTSTART:20261101T003000", "RRULE:FREQ=DAILY;UNTIL=20261104T043000Z"))),
    "all-day weekly until a date":
        (TPE, ("2026-10-01", "2027-01-01"),
         cal(*event("DTSTART;VALUE=DATE:20261001", "DTEND;VALUE=DATE:20261003", "RRULE:FREQ=WEEKLY;UNTIL=20261029"))),
    "RDATE and EXDATE as dates and times":
        (TPE, ("2026-10-01", "2027-01-01"),
         cal(*event(tpe("20261001T090000"), "RRULE:FREQ=WEEKLY;COUNT=5",
                    "RDATE;TZID=Asia/Taipei:20261003T150000,20261004T090000", "RDATE;VALUE=DATE:20261005",
                    "EXDATE;VALUE=DATE:20261008", "EXDATE:20261015T010000Z"))),
    "repeated and skipped wall times in New York":
        (NYC, ("2026-10-01", "2027-04-01"),
         cal(*event(nyc("20261030T013000"), "DURATION:PT30M", "RRULE:FREQ=DAILY;COUNT=5", uid="fall"),
             *event(nyc("20270312T023000"), "DURATION:PT1H", "RRULE:FREQ=DAILY;COUNT=4", uid="spring"))),
    "weekly in a feed's own DST zone":
        (TPE, ("2026-10-01", "2026-12-01"),
         cal(*CET, *event("DTSTART;TZID=W. Europe Custom:20261001T080000",
                          "DTEND;TZID=W. Europe Custom:20261001T090000", "RRULE:FREQ=WEEKLY;BYDAY=TH,SU"))),
    "lower case, a plus sign and a trailing semicolon":
        (TPE, WIDE, cal(*event(tpe("20260105T090000"), "rrule:freq=monthly;byday=+1mo,-1fr;count=04;"))),
    "a sign without a number is not read":
        (TPE, WIDE, cal(*event(tpe("20260105T090000"), "RRULE:FREQ=WEEKLY;BYDAY=+MO"))),
    "BYMONTHDAY=0 matches every day":
        (TPE, WIDE, cal(*event(tpe("20260105T090000"), "RRULE:FREQ=MONTHLY;BYMONTHDAY=0;COUNT=5"))),
    "plain and numbered weekdays must both match":
        (TPE, WIDE, cal(*event(tpe("20260105T090000"), "RRULE:FREQ=MONTHLY;BYDAY=MO,1MO;COUNT=3"))),
    "BYWEEKDAY is BYDAY, COUNT=0 only DTSTART":
        (TPE, WIDE, cal(*event(tpe("20260105T090000"), "RRULE:FREQ=WEEKLY;BYWEEKDAY=TU;COUNT=3", uid="a"),
                        *event(tpe("20260105T090000"), "RRULE:FREQ=DAILY;COUNT=0", uid="b"))),
    "a time listed twice keeps the zone dateutil's heap gives it":
        (NYC, ("2026-08-01", "2026-09-01"),
         cal(*event("DTSTART;TZID=Australia/Sydney:20260803T023000", "DURATION:P1D", "RRULE:FREQ=DAILY;COUNT=4",
                    "RDATE;TZID=America/New_York:20260803T123000"))),
    "an unreadable RECURRENCE-ID names no day of an all-day series":
        (TPE, ("2026-10-01", "2026-11-01"),
         cal(*event("DTSTART;VALUE=DATE:20261012", "RRULE:FREQ=DAILY;COUNT=3", uid="a"),
             *event("RECURRENCE-ID;VALUE=DATE:20261033", "DTSTART;VALUE=DATE:20261020", uid="a", summary="moved"))),
    "a series from 1400 runs away":
        (TPE, ("2026-10-01", "2026-11-01"), cal(*event(tpe("14000101T090000"), "RRULE:FREQ=DAILY"))),
    "at most 500 occurrences":
        (TPE, WIDE, cal(*event(tpe("20260101T090000"), "RRULE:FREQ=DAILY"))),
}

FILES = [("2026-10-01", "2026-11-01"), ("2026-11-01", "2026-12-01")]


def when(value) -> str:
    return value.isoformat()


def parse(text: bytes, zone: str, window: tuple[str, str], **kw) -> dict:
    tz = ZoneInfo(zone)
    start, end = (datetime.combine(date.fromisoformat(d), time(), tz) for d in window)
    try:
        feed = ical.parse(text, start, end, tz, **kw)
    except ical.ICalError:
        return {"error": "ICalError"}
    return {"name": feed.name, "skipped": feed.skipped,
            "events": [[e.title, when(e.start), when(e.end), e.all_day, e.calendar, e.location, e.color]
                       for e in feed.events],
            "tasks": [[t.title, t.due.isoformat() if t.due else None, t.list_name, t.notes] for t in feed.tasks]}


def main() -> None:
    files = []
    for path in sorted((REPO / "shared/vectors/ical").glob("*.ics")):
        for window in FILES:
            files.append({"file": "shared/vectors/ical/" + path.name, "zone": NYC, "window": window,
                          "name": "我的", "color": "#ff0000",
                          "result": parse(path.read_bytes(), NYC, window, name="我的", color="#ff0000")})
    rules = [{"name": name, "zone": zone, "window": window, "ics": text,
              "result": parse(text.encode(), zone, window)} for name, (zone, window, text) in RULES.items()]
    out = {"files": files, "rules": rules}
    (HERE / "parse-expectations.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n",
                                                  encoding="utf-8")
    print(f"{len(files)} file cases, {len(rules)} rule cases")


if __name__ == "__main__":
    main()
