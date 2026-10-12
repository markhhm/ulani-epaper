from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

from ulani_epaper import ical
from ulani_epaper.agenda import Task

FIX = Path(__file__).resolve().parents[2] / "shared" / "vectors" / "ical"
TPE = timezone(timedelta(hours=8))
OCT = (datetime(2026, 10, 1, tzinfo=TPE), datetime(2026, 11, 1, tzinfo=TPE))
NOV = (datetime(2026, 11, 1, tzinfo=TPE), datetime(2026, 12, 1, tzinfo=TPE))


def load(fixture, window=OCT, **kw):
    return ical.parse((FIX / fixture).read_bytes(), *window, tz=TPE, **kw)


def at(day, hh, mm=0, month=10):
    return datetime(2026, month, day, hh, mm, tzinfo=TPE)


def table(feed):
    """[(title, start, end)] in local time, sorted; all-day as dates."""
    rows = []
    for e in feed.events:
        if e.all_day:
            rows.append((e.title, e.start, e.end))
        else:
            rows.append((e.title, e.start.astimezone(TPE), e.end.astimezone(TPE)))
    return sorted(rows, key=lambda r: (str(r[1]), r[0]))


def test_google_feed_october():
    feed = load("google.ics")
    assert feed.name == "個人"
    assert table(feed) == sorted([
        ("晨會", at(5, 9), at(5, 9, 30)),
        ("晨會", at(12, 9), at(12, 9, 30)),  # 19th: EXDATE
        ("晨會（改到十點）", at(26, 10), at(26, 10, 30)),  # override of the 26th
        ("晨會（提前補開）", at(31, 11), at(31, 11, 30)),  # the 30 Nov instance, moved into October
        ("墾丁三日遊", date(2026, 10, 10), date(2026, 10, 13)),  # end stays exclusive
        ("媽媽生日", date(2026, 10, 15), date(2026, 10, 16)),  # yearly since 2000
        ("跨國視訊會議", at(19, 9), at(19, 10)),  # 01:00Z
        ("機場接機", at(15, 23), at(16, 1)),
        ("早餐（浮動時間）", at(20, 8), at(20, 9)),  # floating: X-WR-TIMEZONE
        ("", date(2026, 10, 21), date(2026, 10, 22)),  # no SUMMARY: the pages show （無標題）
        ("通勤讀書", at(27, 8), at(27, 8, 45)),  # DURATION, COUNT=3
        ("通勤讀書", at(28, 8), at(28, 8, 45)),
        ("通勤讀書", at(29, 8), at(29, 8, 45)),
        ("提醒（沒有結束時間）", at(28, 15), at(28, 15)),  # no DTEND: zero length
    ], key=lambda r: (str(r[1]), r[0]))


def test_cancelled_and_moved_occurrences_in_november():
    feed = load("google.ics", NOV)
    assert table(feed) == [("晨會", at(d, 9, month=11), at(d, 9, 30, month=11)) for d in (9, 16, 23)]


def test_window_is_half_open_and_keeps_overlapping_events():
    feed = load("google.ics", (at(11, 0), at(12, 0)))
    assert [e.title for e in feed.events] == ["墾丁三日遊"]  # 10-13 Oct overlaps; the 12th's stand-up starts at the end


def test_feed_name_colour_and_location_go_onto_events():
    feed = load("google.ics", name="我的", color="#ff0000")
    standup = next(e for e in feed.events if e.title == "晨會")
    assert (standup.calendar, standup.color, standup.location) == ("我的", "#ff0000", "3F 會議室")
    assert standup.start.utcoffset() == timedelta(hours=8)


def test_outlook_windows_time_zone_and_custom_dst_zone():
    feed = load("outlook.ics")
    rows = table(feed)
    assert ("季度檢討", at(13, 14), at(13, 15)) in rows
    weekly = [(s, e) for t, s, e in rows if t == "跨洲週會"]
    # Tuesdays 20:00 New York time (EDT, -04:00) = Wednesday 08:00 in Taipei; 6 and 13 Oct excluded
    assert weekly == [(at(21, 8), at(21, 9)), (at(28, 8), at(28, 9))]


def test_date_until_with_a_timed_start_and_daylight_saving_end():
    feed = load("outlook.ics", NOV)
    weekly = [e.start for e in feed.events if e.title == "跨洲週會"]
    # after DST ends on 1 Nov, 20:00 EST (-05:00) = 09:00 in Taipei; UNTIL=20261110 keeps the 10th
    assert [s.astimezone(TPE) for s in weekly] == [at(4, 9, month=11), at(11, 9, month=11)]


def test_todos():
    feed = load("todos.ics")
    assert sorted(feed.tasks, key=lambda t: t.title) == sorted([
        Task("繳電費", due=date(2026, 10, 10), list_name="家務"),
        Task("回覆房東訊息", due=date(2026, 10, 12), list_name="家務"),  # 15:00Z = 23:00 local
        Task("預約汽車保養", due=date(2026, 10, 15), list_name="家務", notes="打電話給車廠"),
        Task("買牛奶、雞蛋、吐司", due=None, list_name="家務"),
        Task("跨日的期限", due=date(2026, 10, 17), list_name="家務"),  # 16:00Z = next day local
        Task("每週倒垃圾", due=date(2026, 10, 13), list_name="家務"),  # recurring to-do: as it is now
    ], key=lambda t: t.title)
    assert [e.title for e in feed.events] == ["社區大會"]


def test_todos_ignore_the_window():
    feed = load("todos.ics", NOV)  # open to-dos are shown whatever their due date
    assert len(feed.tasks) == 6


DECLINED = b"""BEGIN:VCALENDAR\r
BEGIN:VEVENT\r
UID:a\r
SUMMARY:accepted\r
DTSTART:20261020T010000Z\r
ATTENDEE;PARTSTAT=ACCEPTED:mailto:Me@Gmail.com\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:b\r
SUMMARY:declined\r
DTSTART:20261021T010000Z\r
ATTENDEE;CN=Someone;PARTSTAT=ACCEPTED:mailto:someone@example.com\r
ATTENDEE;PARTSTAT=DECLINED:mailto:me@gmail.com\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:c\r
SUMMARY:weekly, but declined once\r
DTSTART:20261005T010000Z\r
RRULE:FREQ=WEEKLY;COUNT=3\r
ATTENDEE;PARTSTAT=ACCEPTED:mailto:me@gmail.com\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:c\r
RECURRENCE-ID:20261012T010000Z\r
SUMMARY:weekly, but declined once\r
DTSTART:20261012T010000Z\r
ATTENDEE;PARTSTAT=DECLINED:mailto:me@gmail.com\r
END:VEVENT\r
END:VCALENDAR\r
"""


def test_events_the_owner_declined_are_left_out():
    feed = ical.parse(DECLINED, *OCT, tz=TPE, owner="me@gmail.com")
    assert sorted((e.title, e.start.day) for e in feed.events) == [
        ("accepted", 20), ("weekly, but declined once", 5), ("weekly, but declined once", 19)]


def test_without_an_owner_nothing_is_judged_declined():
    assert len(ical.parse(DECLINED, *OCT, tz=TPE).events) == 5


def cal(*lines):
    return ("BEGIN:VCALENDAR\r\n" + "".join(f"{x}\r\n" for x in lines) + "END:VCALENDAR\r\n").encode()


def event(*lines):
    return ["BEGIN:VEVENT", "UID:u", "SUMMARY:x", *lines, "END:VEVENT"]


def starts(feed):
    return sorted(e.start.astimezone(TPE) if isinstance(e.start, datetime) else e.start for e in feed.events)


def test_rdate_without_rrule_adds_dates():
    feed = ical.parse(cal(*event("DTSTART:20261001T020000Z", "RDATE:20261008T020000Z,20261015T020000Z")),
                      *OCT, tz=TPE)
    assert starts(feed) == [at(1, 10), at(8, 10), at(15, 10)]


def test_exdate_can_remove_dtstart_of_an_rdate_set():
    feed = ical.parse(cal(*event("DTSTART:20261001T020000Z", "RDATE:20261008T020000Z", "EXDATE:20261001T020000Z")),
                      *OCT, tz=TPE)
    assert starts(feed) == [at(8, 10)]


def test_dtstart_counts_even_when_the_rule_does_not_match_it():
    # Thursday start, weekly on Mondays: RFC 5545 counts DTSTART as the first occurrence
    feed = ical.parse(cal(*event("DTSTART:20261001T010000Z", "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3")), *OCT, tz=TPE)
    assert starts(feed) == [at(1, 9), at(5, 9), at(12, 9), at(19, 9)]


def test_custom_time_zones_do_not_leak_between_feeds():
    def feed_with(offset):
        return cal("BEGIN:VTIMEZONE", "TZID:Customized Time Zone", "BEGIN:STANDARD", "DTSTART:19700101T000000",
                   f"TZOFFSETFROM:{offset}", f"TZOFFSETTO:{offset}", "END:STANDARD", "END:VTIMEZONE",
                   *event("DTSTART;TZID=Customized Time Zone:20261012T090000", "DURATION:PT1H"))

    west = ical.parse(feed_with("-0500"), *OCT, tz=TPE)
    europe = ical.parse(feed_with("+0100"), *OCT, tz=TPE)
    assert starts(west) == [at(12, 22)] and starts(europe) == [at(12, 16)]


def test_a_repeated_summary_uses_the_first():
    feed = ical.parse(cal("BEGIN:VEVENT", "UID:u", "SUMMARY:一", "SUMMARY:二", "DTSTART;VALUE=DATE:20261012",
                          "END:VEVENT"), *OCT, tz=TPE)
    assert [e.title for e in feed.events] == ["一"]


def test_floating_times_use_the_given_zone_without_x_wr_timezone():
    data = (b"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nSUMMARY:f\r\nDTSTART:20261020T080000\r\n"
            b"DTEND:20261020T090000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    feed = ical.parse(data, *OCT, tz=TPE)
    assert feed.events[0].start == at(20, 8)


def test_a_broken_event_is_skipped_not_fatal():
    data = (b"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:bad\r\nSUMMARY:bad\r\nDTSTART:20261020T080000\r\n"
            b"RRULE:FREQ=SOMETIMES\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:ok\r\nSUMMARY:ok\r\n"
            b"DTSTART;VALUE=DATE:20261020\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    feed = ical.parse(data, *OCT, tz=TPE)
    assert [e.title for e in feed.events] == ["ok"] and feed.skipped == 1


@pytest.mark.parametrize("data", [b"", b"<html>not a calendar</html>", b"BEGIN:VCARD\r\nEND:VCARD\r\n"])
def test_not_a_calendar(data):
    with pytest.raises(ical.ICalError):
        ical.parse(data, *OCT, tz=TPE)


def test_committed_vectors_match_the_parser():
    # regenerate (from the repo root): python -m ulani_epaper.ical shared/vectors/ical shared/vectors/ical-vectors.json
    import json

    committed = json.loads((FIX.parent / "ical-vectors.json").read_text(encoding="utf-8"))
    assert committed == ical.vectors(str(FIX))
    files = {case["file"] for case in committed["cases"]}
    assert files == {"google.ics", "outlook.ics", "todos.ics"}


def series(dtstart, rule):
    return (b"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:d\r\nSUMMARY:often\r\n"
            b"DTSTART;TZID=Asia/Taipei:" + dtstart + b"\r\nDURATION:PT10M\r\n"
            b"RRULE:" + rule + b"\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")


def test_a_runaway_rule_is_skipped_quickly():
    import time

    t0 = time.perf_counter()
    feed = ical.parse(series(b"19700101T070000", b"FREQ=MINUTELY;INTERVAL=30"), *OCT, tz=TPE)
    assert time.perf_counter() - t0 < 10
    assert feed.events == [] and feed.skipped == 1


def test_a_dense_series_inside_the_window_is_capped():
    feed = ical.parse(series(b"20261001T000000", b"FREQ=MINUTELY;INTERVAL=30"), *OCT, tz=TPE)
    assert len(feed.events) == ical.MAX_OCCURRENCES


def test_a_daily_event_since_years_ago_is_expanded():
    feed = ical.parse(series(b"20100101T070000", b"FREQ=DAILY"), *OCT, tz=TPE)
    assert len(feed.events) == 31 and feed.skipped == 0
