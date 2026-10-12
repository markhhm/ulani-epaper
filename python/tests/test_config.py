import json

import pytest

from ulani_epaper import config
from ulani_epaper.protocol import UlaniError


def test_defaults_when_there_is_no_file(tmp_path):
    s = config.load(tmp_path / "settings.json")
    assert s.pages == {1: "month", 2: "agenda", 3: "todo", 4: "photo"}
    assert s.feeds == []
    assert s.times == [] and s.language is None  # no sync times until the user picks some


def test_round_trip(tmp_path):
    path = tmp_path / "sub" / "settings.json"
    s = config.Settings(pages={1: "todo", 2: "photo", 3: "photo", 4: "month"},
                        feeds=[config.Feed("a1b2c3d4", "個人", "blue"), config.Feed("e5f6a7b8", "學校", "")],
                        times=["07:30", "21:00"], address="AA:BB:CC:DD:EE:FF")
    config.save(s, path)
    assert config.load(path) == s
    raw = json.loads(path.read_text(encoding="utf-8"))
    assert raw["pages"] == {"1": "todo", "2": "photo", "3": "photo", "4": "month"}
    assert raw["feeds"][0] == {"id": "a1b2c3d4", "name": "個人", "color": "blue"}
    assert "url" not in json.dumps(raw)  # the address is a secret: never in the settings file


def test_settings_from_the_google_api_version_still_load(tmp_path):
    path = tmp_path / "s.json"
    path.write_text('{"pages": {"1": "todo"}, "calendars": ["a@x"], "task_lists": null}', encoding="utf-8")
    s = config.load(path)
    assert s.pages[1] == "todo" and s.feeds == []


@pytest.mark.parametrize("feeds", [
    [config.Feed("a1", "x", "purple")],
    [config.Feed("a1", "x"), config.Feed("a1", "y")],
    [config.Feed("", "x")],
    [config.Feed("a1", " ")],
])
def test_invalid_feeds_are_refused(tmp_path, feeds):
    with pytest.raises(ValueError):
        config.save(config.Settings(feeds=feeds), tmp_path / "s.json")


def test_feed_colours_may_be_palette_names_or_hex(tmp_path):
    path = tmp_path / "s.json"
    config.save(config.Settings(feeds=[config.Feed("a1", "x", "orange"), config.Feed("b2", "y", "#33b679")]), path)
    assert [f.color for f in config.load(path).feeds] == ["orange", "#33b679"]


def test_board_kinds_are_page_kinds(tmp_path):
    assert config.PAGE_NAMES["board"] == "留言板" and config.PAGE_NAMES["message"] == "大字留言"
    assert set(config.PAGE_KINDS) == {"photo", *config.CALENDAR_KINDS, *config.BOARD_KINDS}
    s = config.Settings(pages={1: "month", 2: "message", 3: "photo", 4: "board"})
    config.save(s, tmp_path / "s.json")
    assert config.load(tmp_path / "s.json").pages == s.pages
    assert s.board_pages() == {2: "message", 4: "board"}
    assert s.calendar_pages() == {1: "month", 2: "message", 4: "board"}  # sync draws them all
    assert config.Settings().pages == {1: "month", 2: "agenda", 3: "todo", 4: "photo"}  # defaults unchanged


def test_calendar_pages_leave_photos_alone():
    s = config.Settings(pages={1: "month", 2: "photo", 3: "todo", 4: "photo"})
    assert s.calendar_pages() == {1: "month", 3: "todo"}


@pytest.mark.parametrize("bad", [
    {"pages": {1: "weather"}},
    {"pages": {5: "month"}},
    {"times": ["25:00"]},
    {"times": ["7:30"]},
    {"language": "fr"},
])
def test_invalid_settings_are_refused(tmp_path, bad):
    with pytest.raises(ValueError):
        config.save(config.Settings(**bad), tmp_path / "s.json")


def test_times_are_sorted_and_unique(tmp_path):
    path = tmp_path / "s.json"
    config.save(config.Settings(times=["18:00", "06:00", "18:00"]), path)
    assert config.load(path).times == ["06:00", "18:00"]


def test_missing_pages_keep_their_defaults(tmp_path):
    path = tmp_path / "s.json"
    path.write_text('{"pages": {"4": "todo"}}', encoding="utf-8")
    assert config.load(path).pages == {1: "month", 2: "agenda", 3: "todo", 4: "todo"}


def test_a_broken_file_is_reported(tmp_path):
    path = tmp_path / "s.json"
    path.write_text("{not json", encoding="utf-8")
    with pytest.raises(UlaniError, match="settings"):
        config.load(path)


def test_saving_replaces_the_file_atomically(tmp_path):
    path = tmp_path / "s.json"
    config.save(config.Settings(), path)
    config.save(config.Settings(times=["08:00"]), path)
    assert [p.name for p in tmp_path.iterdir()] == ["s.json"]


def test_config_dir_can_be_overridden(monkeypatch, tmp_path):
    monkeypatch.setenv("ULANI_CONFIG_DIR", str(tmp_path))
    assert config.config_dir() == tmp_path
    assert config.settings_path() == tmp_path / "settings.json"


def test_no_times_is_a_valid_setting_and_a_file_without_times_has_none(tmp_path):
    path = tmp_path / "s.json"
    config.save(config.Settings(times=[]), path)
    assert config.load(path).times == []
    path.write_text('{"pages": {"1": "todo"}}', encoding="utf-8")
    assert config.load(path).times == []


def test_settings_language_round_trip_and_bad_value(tmp_path):
    path = tmp_path / "s.json"
    config.save(config.Settings(language="en"), path)
    assert config.load(path).language == "en" and json.loads(path.read_text(encoding="utf-8"))["language"] == "en"
    config.save(config.Settings(), path)
    assert "language" not in json.loads(path.read_text(encoding="utf-8"))  # absent = follow the system
    with pytest.raises(ValueError):
        config.save(config.Settings(language="fr"), path)
    path.write_text('{"language": "fr", "times": ["07:00"]}', encoding="utf-8")
    assert config.load(path).language is None and config.load(path).times == ["07:00"]  # tolerated, not fatal
