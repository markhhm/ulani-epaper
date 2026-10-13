"""web/scripts/tw_holidays.py: the default calendar file of the web app (made by CI every day)."""

import importlib.util
import json
from datetime import date, timedelta
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "web" / "scripts" / "tw_holidays.py"
spec = importlib.util.spec_from_file_location("tw_holidays", SCRIPT)
tw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tw)

# What Google's public Taiwan holidays calendar looks like: all-day events with DATE values.
ICS = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Google Inc//Google Calendar 70.9054//EN
X-WR-CALNAME:台灣的節慶假日
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261010
DTEND;VALUE=DATE:20261011
UID:national-day@google.com
SUMMARY:國慶日
DESCRIPTION:公眾假期
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261025
DTEND;VALUE=DATE:20261026
UID:restoration@google.com
SUMMARY:臺灣光復節
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20250101
DTEND;VALUE=DATE:20250102
UID:long-ago@google.com
SUMMARY:元旦 2025
END:VEVENT
END:VCALENDAR
""".replace("\n", "\r\n").encode("utf-8")


def test_the_payload_has_the_shortcut_format():
    payload = tw.convert(ICS, date(2026, 10, 12))
    assert payload == {
        "v": 1,
        "events": [
            {"title": "國慶日", "start": "2026-10-10T00:00:00+08:00", "end": "2026-10-11T00:00:00+08:00",
             "allDay": True, "calendar": "台灣假日"},
            {"title": "臺灣光復節", "start": "2026-10-25T00:00:00+08:00", "end": "2026-10-26T00:00:00+08:00",
             "allDay": True, "calendar": "台灣假日"},
        ],
        "reminders": [],
    }


def test_only_the_days_the_pages_can_show_are_kept():
    titles = [e["title"] for e in tw.convert(ICS, date(2026, 10, 12))["events"]]
    assert "元旦 2025" not in titles
    assert "元旦 2025" in [e["title"] for e in tw.convert(ICS, date(2025, 1, 5))["events"]]


def _day(uid: str, ymd: str, title: str) -> str:
    """An all-day event on `ymd` (YYYYMMDD), as Google writes one."""
    day = date(int(ymd[:4]), int(ymd[4:6]), int(ymd[6:]))
    end = (day + timedelta(days=1)).strftime("%Y%m%d")
    return (f"BEGIN:VEVENT\r\nDTSTART;VALUE=DATE:{ymd}\r\nDTEND;VALUE=DATE:{end}\r\n"
            f"UID:{uid}@google.com\r\nSUMMARY:{title}\r\nEND:VEVENT\r\n")


def test_the_file_reaches_the_end_of_next_year_so_a_stopped_daily_job_degrades_slowly():
    # GitHub switches scheduled workflows off after 60 days without activity: the copy on the site must
    # keep the holidays of the months after that, not run dry a month later.
    feed = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Google Inc//Google Calendar 70.9054//EN\r\n"
            + _day("a", "20270301", "和平紀念日 2027") + _day("b", "20271231", "年末 2027")
            + _day("c", "20280101", "元旦 2028") + "END:VCALENDAR\r\n").encode("utf-8")
    titles = [e["title"] for e in tw.convert(feed, date(2026, 10, 12))["events"]]
    assert titles == ["和平紀念日 2027", "年末 2027"]  # next year to its last day; the year after is not kept


def test_the_file_is_utf8_json_without_escapes(tmp_path):
    out = tmp_path / "data" / "tw-holidays.json"
    tw.write(out, tw.convert(ICS, date(2026, 10, 12)))
    raw = out.read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf") and raw.endswith(b"\n")
    assert "國慶日" in raw.decode("utf-8")  # readable, not \u escapes
    assert json.loads(raw)["v"] == 1


def test_something_that_is_not_a_calendar_stops_without_writing(tmp_path):
    page = tmp_path / "page.html"
    page.write_text("<html>sorry</html>", encoding="utf-8")
    out = tmp_path / "out.json"
    with pytest.raises(SystemExit) as stop:
        tw.main([str(out), str(page)])  # the second argument reads a file instead of downloading
    assert stop.value.code not in (0, None)
    assert not out.exists()
