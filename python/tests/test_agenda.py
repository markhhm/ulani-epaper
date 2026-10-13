import time as _time
from datetime import date, datetime, time, timedelta, timezone

import pytest

from ulani_epaper.agenda import LOCAL, AgendaData, Event, Task

TPE = timezone(timedelta(hours=8))


def ev(title, start, end, all_day=False, cal="個人"):
    return Event(title=title, start=start, end=end, all_day=all_day, calendar=cal)


def test_events_on_a_day_all_day_first_then_by_start_time():
    data = AgendaData(events=(
        ev("午餐", datetime(2026, 10, 12, 12, 0, tzinfo=TPE), datetime(2026, 10, 12, 13, 0, tzinfo=TPE)),
        ev("連假", date(2026, 10, 10), date(2026, 10, 13), all_day=True),  # end is exclusive
        ev("早會", datetime(2026, 10, 12, 9, 0, tzinfo=TPE), datetime(2026, 10, 12, 9, 30, tzinfo=TPE)),
        ev("明天", datetime(2026, 10, 13, 9, 0, tzinfo=TPE), datetime(2026, 10, 13, 10, 0, tzinfo=TPE)),
    ))
    assert [e.title for e in data.events_on(date(2026, 10, 12), TPE)] == ["連假", "早會", "午餐"]
    assert [e.title for e in data.events_on(date(2026, 10, 13), TPE)] == ["明天"]  # 連假 ended (exclusive)


def test_timed_events_use_the_given_time_zone():
    utc_late = datetime(2026, 10, 12, 17, 0, tzinfo=timezone.utc)  # 01:00 on the 13th in Taipei
    data = AgendaData(events=(ev("深夜", utc_late, utc_late + timedelta(hours=1)),))
    assert data.events_on(date(2026, 10, 12), TPE) == []
    assert [e.title for e in data.events_on(date(2026, 10, 13), TPE)] == ["深夜"]


def test_an_event_spanning_midnight_shows_on_both_days():
    data = AgendaData(events=(ev("跨夜", datetime(2026, 10, 12, 22, 0, tzinfo=TPE),
                                 datetime(2026, 10, 13, 2, 0, tzinfo=TPE)),))
    assert data.events_on(date(2026, 10, 12), TPE) and data.events_on(date(2026, 10, 13), TPE)
    assert data.events_on(date(2026, 10, 14), TPE) == []


def test_open_tasks_sorted_by_due_date_then_undated():
    data = AgendaData(tasks=(
        Task("沒期限"), Task("下週", due=date(2026, 10, 19)), Task("昨天", due=date(2026, 10, 11)),
    ))
    assert [t.title for t in data.sorted_tasks()] == ["昨天", "下週", "沒期限"]


def test_json_round_trip_keeps_dates_times_and_zones():
    data = AgendaData(
        events=(ev("早會", datetime(2026, 10, 12, 9, 0, tzinfo=TPE), datetime(2026, 10, 12, 9, 30, tzinfo=TPE)),
                ev("連假", date(2026, 10, 10), date(2026, 10, 13), all_day=True)),
        tasks=(Task("繳費", due=date(2026, 10, 15), list_name="家務", notes="電費"),),
        fetched_at=datetime(2026, 10, 12, 7, 0, tzinfo=TPE),
    )
    again = AgendaData.from_json(data.to_json())
    assert again == data
    assert again.events[0].start.utcoffset() == timedelta(hours=8)


def test_from_json_tolerates_missing_optional_fields():
    data = AgendaData.from_json('{"events": [{"title": "x", "start": "2026-10-12", "end": "2026-10-13", '
                                '"all_day": true}], "tasks": [{"title": "y"}]}')
    assert data.events[0].calendar == "" and data.tasks[0].due is None and data.fetched_at is None
    assert data.events[0].color == ""


def check_local_matches_the_os():
    for month in range(1, 13):
        stamp = datetime(2026, month, 15, 12, tzinfo=timezone.utc).timestamp()
        assert datetime.fromtimestamp(stamp, LOCAL).utcoffset() == timedelta(seconds=_time.localtime(stamp).tm_gmtoff)
        midnight = datetime.combine(date(2026, month, 15), time(), LOCAL)
        assert midnight.timestamp() == _time.mktime((2026, month, 15, 0, 0, 0, 0, 0, -1))
        assert midnight.astimezone(timezone.utc).astimezone(LOCAL).replace(tzinfo=None) == datetime(2026, month, 15)


def test_local_time_zone_follows_the_os():
    check_local_matches_the_os()


@pytest.mark.skipif(not hasattr(_time, "tzset"), reason="time.tzset() is POSIX only")
def test_local_time_zone_handles_daylight_saving(monkeypatch):
    monkeypatch.setenv("TZ", "America/New_York")
    _time.tzset()
    try:
        assert datetime.combine(date(2026, 1, 15), time(), LOCAL).utcoffset() == timedelta(hours=-5)
        assert datetime.combine(date(2026, 7, 15), time(), LOCAL).utcoffset() == timedelta(hours=-4)
        check_local_matches_the_os()
    finally:
        monkeypatch.delenv("TZ")
        _time.tzset()


@pytest.mark.parametrize("year", [1900, 1969, 3001, 9999])
def test_local_time_zone_never_fails_outside_the_os_range(year):
    # Windows' C runtime refuses dates before 1970 and after 3000
    assert datetime(year, 6, 1, tzinfo=LOCAL).utcoffset() is not None


def test_event_colour_round_trips():
    data = AgendaData(events=(Event("x", date(2026, 10, 12), date(2026, 10, 13), all_day=True, color="#4986e7"),))
    assert AgendaData.from_json(data.to_json()).events[0].color == "#4986e7"
