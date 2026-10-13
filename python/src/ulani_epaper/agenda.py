"""Calendar events and to-do tasks, independent of where they come from.

This is the data model shared by the iCal reader, the page layouts, the
sync engine and the JSON fixtures that the Apple port is tested against.
Dates follow iCalendar's conventions: all-day events use dates with an
exclusive end; timed events use time-zone-aware datetimes.
"""

from __future__ import annotations

import json
import time as _time
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, tzinfo
from typing import Any


class _LocalTime(tzinfo):
    """The OS's local time zone, daylight-saving rules included.

    datetime.now().astimezone().tzinfo is a fixed offset, which is wrong for
    days on the other side of a DST change; this asks the OS for every instant.
    """

    def utcoffset(self, dt: datetime | None) -> timedelta:
        return timedelta(seconds=self._local(dt).tm_gmtoff)

    def dst(self, dt: datetime | None) -> timedelta:
        return timedelta(hours=1) if self._local(dt).tm_isdst > 0 else timedelta(0)

    def tzname(self, dt: datetime | None) -> str:
        return self._local(dt).tm_zone

    def fromutc(self, dt: datetime) -> datetime:
        stamp = (dt.replace(tzinfo=None) - datetime(1970, 1, 1)).total_seconds()
        try:
            offset = _time.localtime(stamp).tm_gmtoff
        except (OverflowError, OSError, ValueError):
            offset = _time.localtime().tm_gmtoff
        return dt + timedelta(seconds=offset)

    @staticmethod
    def _local(dt: datetime | None) -> _time.struct_time:
        if dt is None:
            return _time.localtime()
        try:
            return _time.localtime(_time.mktime((dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, 0, 0, -1)))
        except (OverflowError, OSError, ValueError):  # outside the OS range (Windows: 1970-3000): today's rules
            return _time.localtime()

    def __repr__(self) -> str:
        return "LOCAL"


#: This computer's time zone.
LOCAL = _LocalTime()


@dataclass(frozen=True)
class Event:
    title: str
    start: date | datetime  # date for all-day events
    end: date | datetime  # exclusive
    all_day: bool = False
    calendar: str = ""
    location: str = ""
    color: str = ""  # the calendar's colour, "#rrggbb"; "" = none

    def _range(self, tz: tzinfo) -> tuple[datetime, datetime]:
        if self.all_day:
            return (datetime.combine(self.start, time(), tz), datetime.combine(self.end, time(), tz))
        return self.start.astimezone(tz), self.end.astimezone(tz)

    def overlaps(self, day: date, tz: tzinfo) -> bool:
        start, end = self._range(tz)
        day_start = datetime.combine(day, time(), tz)
        day_end = datetime.combine(date.fromordinal(day.toordinal() + 1), time(), tz)
        if start == end:  # zero-length event: show on the day it happens
            return day_start <= start < day_end
        return start < day_end and end > day_start

    def start_in(self, tz: tzinfo) -> datetime:
        return self._range(tz)[0]


@dataclass(frozen=True)
class Task:
    title: str
    due: date | None = None
    list_name: str = ""
    notes: str = ""


@dataclass(frozen=True)
class AgendaData:
    events: tuple[Event, ...] = field(default_factory=tuple)
    tasks: tuple[Task, ...] = field(default_factory=tuple)
    fetched_at: datetime | None = None

    def events_on(self, day: date, tz: tzinfo) -> list[Event]:
        """Events touching ``day`` (local), all-day first, then by start time."""
        hits = [e for e in self.events if e.overlaps(day, tz)]
        return sorted(hits, key=lambda e: (not e.all_day, e.start_in(tz), e.title))

    def sorted_tasks(self) -> list[Task]:
        """Open tasks: dated ones by due date first, then the undated ones."""
        return sorted(self.tasks, key=lambda t: (t.due is None, t.due or date.max, t.title))

    # --- JSON ------------------------------------------------------------------

    def to_json(self) -> str:
        return json.dumps({
            "events": [_event_to(e) for e in self.events],
            "tasks": [_task_to(t) for t in self.tasks],
            "fetched_at": self.fetched_at.isoformat() if self.fetched_at else None,
        }, ensure_ascii=False, indent=1)

    @classmethod
    def from_json(cls, text: str) -> "AgendaData":
        raw = json.loads(text)
        fetched = raw.get("fetched_at")
        return cls(
            events=tuple(_event_from(e) for e in raw.get("events", [])),
            tasks=tuple(_task_from(t) for t in raw.get("tasks", [])),
            fetched_at=datetime.fromisoformat(fetched) if fetched else None,
        )


def _when_to(value: date | datetime) -> str:
    return value.isoformat()


def _when_from(text: str) -> date | datetime:
    return datetime.fromisoformat(text) if "T" in text else date.fromisoformat(text)


def _event_to(e: Event) -> dict[str, Any]:
    return {"title": e.title, "start": _when_to(e.start), "end": _when_to(e.end), "all_day": e.all_day,
            "calendar": e.calendar, "location": e.location, "color": e.color}


def _event_from(d: dict[str, Any]) -> Event:
    return Event(title=d["title"], start=_when_from(d["start"]), end=_when_from(d["end"]),
                 all_day=bool(d.get("all_day", False)), calendar=d.get("calendar", ""),
                 location=d.get("location", ""), color=d.get("color", ""))


def _task_to(t: Task) -> dict[str, Any]:
    return {"title": t.title, "due": t.due.isoformat() if t.due else None, "list_name": t.list_name,
            "notes": t.notes}


def _task_from(d: dict[str, Any]) -> Task:
    return Task(title=d["title"], due=date.fromisoformat(d["due"]) if d.get("due") else None,
                list_name=d.get("list_name", ""), notes=d.get("notes", ""))
