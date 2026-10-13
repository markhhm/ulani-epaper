"""Read events and to-dos from iCalendar (.ics) data.

Any calendar that publishes an .ics address works: Google Calendar's
"secret address in iCal format", Outlook, iCloud, Nextcloud, Fastmail, ...
Recurring events are expanded inside a time window (RRULE, RDATE, EXDATE,
and RECURRENCE-ID overrides that move or cancel one occurrence). Open
to-dos (VTODO) are returned whatever their due date.

Parsing uses icalendar (BSD) and dateutil's rrule (BSD/Apache); the
expansion is done here so that everything shipped stays permissively
licensed. Nothing is cached: the caller passes the bytes in and gets
Events and Tasks back.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, timezone, tzinfo
from typing import Iterable

import icalendar
from dateutil.rrule import rruleset, rrulestr

from .agenda import Event, Task
from .protocol import UlaniError

#: At most this many occurrences of one recurring event inside the window.
MAX_OCCURRENCES = 500
#: Rule steps walked from DTSTART before an event is given up as runaway.
MAX_STEPS = 200_000


class ICalError(UlaniError):
    """The data is not an iCalendar file."""


class _Runaway(Exception):
    pass


@dataclass
class ParsedFeed:
    name: str  # the name given, else the calendar's X-WR-CALNAME
    events: list[Event] = field(default_factory=list)
    tasks: list[Task] = field(default_factory=list)
    skipped: int = 0  # events that could not be read (bad rule, missing start, ...)


def _zone(name) -> tzinfo | None:
    if not name:
        return None
    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo(str(name).strip())
    except Exception:  # unknown or malformed zone name
        return None


def _text(comp, key: str) -> str:
    value = comp.get(key, "")
    if isinstance(value, list):  # a property written twice: use the first
        value = value[0] if value else ""
    return str(value).strip()


def _declined(comp, owner: str) -> bool:
    """The owner's own ATTENDEE line says PARTSTAT=DECLINED (Google keeps declined
    invitations in the feed; this is the only sign of the decline)."""
    if not owner:
        return False
    attendees = comp.get("ATTENDEE")
    for a in attendees if isinstance(attendees, list) else [attendees] if attendees is not None else []:
        if str(a).lower().removeprefix("mailto:") == owner.lower():
            return str(a.params.get("PARTSTAT", "")).upper() == "DECLINED"
    return False


class _Reader:
    def __init__(self, start: datetime, end: datetime, tz: tzinfo, floating: tzinfo) -> None:
        self.start, self.end, self.tz, self.floating = start, end, tz, floating

    # --- time values ------------------------------------------------------------

    def window(self, sample: datetime | date) -> tuple[datetime, datetime]:
        """The window in the same kind of value as ``sample`` (aware, or naive wall time)."""
        if isinstance(sample, datetime) and sample.tzinfo is not None:
            return self.start, self.end
        zone = self.tz if not isinstance(sample, datetime) else self.floating
        return (self.start.astimezone(zone).replace(tzinfo=None), self.end.astimezone(zone).replace(tzinfo=None))

    def like(self, value, base: datetime):
        """``value`` (date, naive or aware datetime) as the same kind of value as ``base``."""
        if base.tzinfo is None:
            if not isinstance(value, datetime):
                return datetime.combine(value, time())
            return value.astimezone(self.floating).replace(tzinfo=None) if value.tzinfo else value
        if not isinstance(value, datetime):
            return datetime.combine(value, base.timetz())
        return value if value.tzinfo else value.replace(tzinfo=base.tzinfo)

    def until(self, value, base: datetime) -> str:
        """RRULE UNTIL in the form dateutil accepts for this DTSTART (UTC if it is aware)."""
        if not isinstance(value, datetime):
            value = datetime.combine(value, time(23, 59, 59))  # a date: through that day
        if base.tzinfo is None:
            return self.like(value, base).strftime("%Y%m%dT%H%M%S")
        if value.tzinfo is None:
            value = value.replace(tzinfo=base.tzinfo)
        return value.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    # --- events -----------------------------------------------------------------

    def start_and_duration(self, comp) -> tuple[datetime, timedelta, bool]:
        start = comp.decoded("DTSTART")
        all_day = not isinstance(start, datetime)
        base = datetime.combine(start, time()) if all_day else start
        if "DTEND" in comp:
            end = self.like(comp.decoded("DTEND"), base)
            if all_day:
                end = datetime.combine(end.date(), time())
            length = end - base
        elif "DURATION" in comp:
            length = comp.decoded("DURATION")
        else:
            length = timedelta(days=1) if all_day else timedelta(0)
        if all_day:
            length = max(length, timedelta(days=1))
        return base, max(length, timedelta(0)), all_day

    def overlaps(self, begin: datetime, length: timedelta, lo: datetime, hi: datetime) -> bool:
        if not length:
            return lo <= begin < hi
        return begin < hi and begin + length > lo

    def occurrences(self, comp, base: datetime, length: timedelta) -> Iterable[datetime]:
        lo, hi = self.window(base)
        rule = comp.get("RRULE")
        if rule is None and comp.get("RDATE") is None and comp.get("EXDATE") is None:
            return [base] if self.overlaps(base, length, lo, hi) else []
        rules = rruleset()
        rules.rdate(base)  # DTSTART always counts (RFC 5545), even when the rule does not match it
        if rule is not None:
            parts = {k: v for k, v in rule.items() if k.upper() != "UNTIL"}
            text = icalendar.vRecur(parts).to_ical().decode()
            if "UNTIL" in rule:
                text += ";UNTIL=" + self.until(rule["UNTIL"][0], base)
            rules.rrule(rrulestr(text, dtstart=base))
        for prop, add in (("RDATE", rules.rdate), ("EXDATE", rules.exdate)):
            values = comp.get(prop)
            for item in values if isinstance(values, list) else [values] if values is not None else []:
                for d in item.dts:
                    if not isinstance(d.dt, tuple):  # RDATE;VALUE=PERIOD is not supported
                        add(self.like(d.dt, base))
        found = []
        for step, begin in enumerate(rules):
            if step >= MAX_STEPS:
                raise _Runaway
            if begin >= hi:
                break
            if self.overlaps(begin, length, lo, hi):
                found.append(begin)
                if len(found) >= MAX_OCCURRENCES:
                    break
        return found

    def key(self, value, all_day: bool):
        """Comparable identity of an occurrence (for RECURRENCE-ID)."""
        if all_day:
            return value.date() if isinstance(value, datetime) else value
        if not isinstance(value, datetime):
            value = datetime.combine(value, time())
        if value.tzinfo is None:
            value = value.replace(tzinfo=self.floating)
        return value.astimezone(timezone.utc)

    def event(self, comp, begin: datetime, length: timedelta, all_day: bool, name: str, color: str) -> Event:
        if all_day:
            first, last = begin.date(), (begin + length).date()
        else:
            first = begin if begin.tzinfo else begin.replace(tzinfo=self.floating)
            last = first + length
        return Event(title=_text(comp, "SUMMARY"), start=first, end=last, all_day=all_day, calendar=name,
                     location=_text(comp, "LOCATION"), color=color)

    # --- to-dos -----------------------------------------------------------------

    def task(self, comp, name: str) -> Task | None:
        if _text(comp, "STATUS").upper() in ("COMPLETED", "CANCELLED") or "COMPLETED" in comp:
            return None
        if str(comp.get("PERCENT-COMPLETE", "")).strip() == "100":
            return None
        title = _text(comp, "SUMMARY")
        if not title:
            return None
        due = None
        if "DUE" in comp:
            value = comp.decoded("DUE")
            if isinstance(value, datetime):
                due = (value.astimezone(self.tz) if value.tzinfo else value).date()
            else:
                due = value
        notes = next((line.strip() for line in _text(comp, "DESCRIPTION").splitlines() if line.strip()), "")
        return Task(title=title, due=due, list_name=name, notes=notes)


def vectors(fixtures: str) -> dict:
    """Expected results for every ``fixtures/*.ics`` in two windows (October and
    November 2026, UTC+8): the reference for other implementations (the Swift
    port). Times are written in UTC+8; dates as YYYY-MM-DD."""
    import os

    tz = timezone(timedelta(hours=8))
    windows = [(datetime(2026, 10, 1, tzinfo=tz), datetime(2026, 11, 1, tzinfo=tz)),
               (datetime(2026, 11, 1, tzinfo=tz), datetime(2026, 12, 1, tzinfo=tz))]

    def when(value) -> str:
        return value.astimezone(tz).isoformat() if isinstance(value, datetime) else value.isoformat()

    cases = []
    for name in sorted(n for n in os.listdir(fixtures) if n.endswith(".ics")):
        with open(os.path.join(fixtures, name), "rb") as f:
            data = f.read()
        for start, end in windows:
            feed = parse(data, start, end, tz)
            events = [{"title": e.title, "start": when(e.start), "end": when(e.end), "all_day": e.all_day,
                       "location": e.location} for e in feed.events]
            tasks = [{"title": t.title, "due": t.due.isoformat() if t.due else None, "notes": t.notes}
                     for t in feed.tasks]
            cases.append({"file": name, "window": [start.isoformat(), end.isoformat()], "name": feed.name,
                          "skipped": feed.skipped,
                          "events": sorted(events, key=lambda e: (e["start"], e["title"])),
                          "tasks": sorted(tasks, key=lambda t: t["title"])})
    return {"version": 1, "utc_offset": "+08:00", "cases": cases}


def parse(data: bytes, start: datetime, end: datetime, tz: tzinfo, name: str = "", color: str = "",
          owner: str = "") -> ParsedFeed:
    """Events overlapping [start, end) and all open to-dos of one .ics file.

    ``start``/``end`` are time-zone aware; ``tz`` is the zone the pages are
    drawn in (all-day dates and due dates are read in it). ``name`` and
    ``color`` ("#rrggbb") are put on every event and to-do. Events whose
    ATTENDEE line for ``owner`` (an e-mail address) says DECLINED are left out;
    each moved occurrence is judged on its own.
    """
    # icalendar caches VTIMEZONE definitions by TZID for the whole process (first one wins):
    # start every feed afresh, or two feeds' "Customized Time Zone" would share one offset
    icalendar.use_zoneinfo()
    try:
        cal = icalendar.Calendar.from_ical(data)
    except Exception as e:  # icalendar raises ValueError and friends for non-iCalendar data
        raise ICalError(f"not an iCalendar file ({type(e).__name__})") from None
    if getattr(cal, "name", "") != "VCALENDAR":
        raise ICalError("not an iCalendar file (no VCALENDAR)")
    floating = _zone(cal.get("X-WR-TIMEZONE")) or tz
    feed = ParsedFeed(name=name or _text(cal, "X-WR-CALNAME"))
    reader = _Reader(start, end, tz, floating)

    masters, overrides = [], {}
    for comp in cal.walk("VEVENT"):
        if "RECURRENCE-ID" in comp:
            overrides.setdefault(_text(comp, "UID"), []).append(comp)
        else:
            masters.append(comp)

    for comp in masters:
        if _text(comp, "STATUS").upper() == "CANCELLED" or _declined(comp, owner):
            continue
        try:
            base, length, all_day = reader.start_and_duration(comp)
            moved = {reader.key(o.decoded("RECURRENCE-ID"), all_day) for o in overrides.get(_text(comp, "UID"), ())}
            for begin in reader.occurrences(comp, base, length):
                if reader.key(begin, all_day) not in moved:
                    feed.events.append(reader.event(comp, begin, length, all_day, feed.name, color))
        except (_Runaway, KeyError, ValueError, TypeError, OverflowError, AttributeError):
            feed.skipped += 1

    for comp in (o for group in overrides.values() for o in group):
        if _text(comp, "STATUS").upper() == "CANCELLED" or _declined(comp, owner):
            continue  # a cancelled or declined occurrence: the master skipped it above
        try:
            base, length, all_day = reader.start_and_duration(comp)
            lo, hi = reader.window(base)
            if reader.overlaps(base, length, lo, hi):
                feed.events.append(reader.event(comp, base, length, all_day, feed.name, color))
        except (KeyError, ValueError, TypeError, OverflowError, AttributeError):
            feed.skipped += 1

    for comp in cal.walk("VTODO"):
        try:
            task = reader.task(comp, feed.name)
        except (KeyError, ValueError, TypeError, OverflowError, AttributeError):
            feed.skipped += 1
            continue
        if task:
            feed.tasks.append(task)
    return feed


if __name__ == "__main__":  # from the repo root: python -m ulani_epaper.ical shared/vectors/ical shared/vectors/ical-vectors.json
    import json
    import sys

    with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as out:
        json.dump(vectors(sys.argv[1]), out, ensure_ascii=False, indent=1)
        out.write("\n")
