"""Make the default calendar of the web app: Taiwan's public holidays as web/dist/data/tw-holidays.json.

The web app shows this calendar when the user has none. Google's own address cannot be read from
another site in a browser, so CI (`.github/workflows/web.yml`, at every build and once a day) downloads
Google's public Taiwan holidays iCal feed, reads it with the Python reference (`ulani_epaper.ical.parse`,
the window of `feeds.window`) and puts the result on the same site as the app. Only public data.

The file is the payload of the iPhone Shortcut (all-day events with midnights and the +08:00 offset):

    {"v": 1, "events": [{"title", "start", "end", "allDay", "calendar"}], "reminders": []}

From the repository root:

    PYTHONPATH=python/src python web/scripts/tw_holidays.py web/dist/data/tw-holidays.json [feed.ics]

With a second argument the feed is read from that file instead of downloaded. The script stops with a
message (and writes nothing) unless it got a calendar. Needs the package's calendar extra
(`pip install "./python[calendar]"`).
"""

from __future__ import annotations

import json
import os
import sys
from datetime import date, datetime, time, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE = os.path.join(os.path.realpath(os.path.join(HERE, "..", "..")), "python", "src", "ulani_epaper")

try:
    from ulani_epaper import feeds, ical
except ImportError:
    sys.exit("ulani_epaper (with the calendar extra) is not importable: run with PYTHONPATH=python/src")
if os.path.realpath(os.path.dirname(feeds.__file__)) != REFERENCE:
    sys.exit(f"ulani_epaper comes from {feeds.__file__}, not from {REFERENCE}")

TAIPEI = timezone(timedelta(hours=8))  # Taiwan has no daylight saving time


def _iso(value: date | datetime) -> str:
    if isinstance(value, datetime):
        return value.astimezone(TAIPEI).isoformat()
    return datetime.combine(value, time(), TAIPEI).isoformat()  # an all-day date: its midnight


def convert(feed: bytes, today: date) -> dict:
    """The payload for the pages drawn on `today`. Raises ical.ICalError when `feed` is not a calendar."""
    first, last = feeds.window(today)
    parsed = ical.parse(feed, datetime.combine(first, time(), TAIPEI), datetime.combine(last, time(), TAIPEI),
                        TAIPEI, name=feeds.DEFAULT_CALENDAR_NAME)
    events = [{"title": e.title, "start": _iso(e.start), "end": _iso(e.end), "allDay": e.all_day,
               "calendar": e.calendar} for e in sorted(parsed.events, key=lambda e: (_iso(e.start), e.title))]
    return {"v": 1, "events": events, "reminders": []}


def write(path, payload: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as out:
        json.dump(payload, out, ensure_ascii=False, separators=(",", ":"))
        out.write("\n")


def main(argv: list[str]) -> None:
    if not 1 <= len(argv) <= 2:
        sys.exit(__doc__)
    try:
        if len(argv) == 2:
            with open(argv[1], "rb") as f:
                body = f.read()
        else:
            body = feeds.download(feeds.DEFAULT_CALENDAR_URL)
        payload = convert(body, datetime.now(TAIPEI).date())
    except (feeds.FeedError, ical.ICalError, OSError) as e:
        sys.exit(f"tw_holidays: {e}")
    write(argv[0], payload)
    print(f"{argv[0]}: {len(payload['events'])} events")


if __name__ == "__main__":
    main(sys.argv[1:])
