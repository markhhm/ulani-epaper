import json

import pytest

from ulani_epaper import config
from ulani_epaper.protocol import UlaniError


def test_defaults_when_there_is_no_file(tmp_path):
    s = config.load(tmp_path / "settings.json")
    assert s.pages == {1: "month", 2: "agenda", 3: "todo", 4: "photo"}
    assert s.feeds == []
    assert s.times == ["06:00", "12:00", "18:00"]


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
    assert set(config.PAGE_KINDS) == {"photo", *config.CALENDAR_KINDS, *config.BOARD_KINDS, *config.CARD_KINDS}
    s = config.Settings(pages={1: "month", 2: "message", 3: "photo", 4: "board"})
    config.save(s, tmp_path / "s.json")
    assert config.load(tmp_path / "s.json").pages == s.pages
    assert s.board_pages() == {2: "message", 4: "board"}
    assert s.calendar_pages() == {1: "month"}  # sync redraws calendar kinds only; boards change when posted
    assert config.Settings().pages == {1: "month", 2: "agenda", 3: "todo", 4: "photo"}  # defaults unchanged


def test_calendar_pages_leave_photos_alone():
    s = config.Settings(pages={1: "month", 2: "photo", 3: "todo", 4: "photo"})
    assert s.calendar_pages() == {1: "month", 3: "todo"}


@pytest.mark.parametrize("bad", [
    {"pages": {1: "weather"}},
    {"pages": {5: "month"}},
    {"times": ["25:00"]},
    {"times": ["7:30"]},
    {"times": []},
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


def test_card_is_a_page_kind_that_sync_never_draws(tmp_path):
    assert config.PAGE_NAMES["card"] == "牌卡" and config.CARD_KINDS == ("card",)
    s = config.Settings(pages={1: "month", 2: "card", 3: "photo", 4: "card"})
    config.save(s, tmp_path / "s.json")
    assert config.load(tmp_path / "s.json").pages == s.pages
    assert s.calendar_pages() == {1: "month"}  # a card page changes only when a card is pushed to it
    assert s.board_pages() == {}


def test_the_cards_on_the_device_pages_are_remembered(tmp_path):
    s = config.Settings(pages={1: "month", 2: "card", 3: "card", 4: "photo"}, card_pages={2: "ab12", 3: "cd34"})
    config.save(s, tmp_path / "s.json")
    assert config.load(tmp_path / "s.json").card_pages == {2: "ab12", 3: "cd34"}
    assert config.Settings().card_pages == {}
    with pytest.raises(ValueError, match="1-4"):
        config.Settings(card_pages={5: "ab12"}).validate()


def test_calendar_page_kinds_and_labels():
    assert config.PAGE_NAMES["month"] == "本日＋月曆" and config.PAGE_NAMES["agenda"] == "本日行程＋一週行程"
    assert config.PAGE_NAMES["day"] == "日" and config.PAGE_NAMES["monthgrid"] == "月曆"
    assert {"day", "monthgrid"} <= set(config.CALENDAR_KINDS) <= set(config.PAGE_KINDS)
    assert config.Settings(pages={1: "day", 2: "monthgrid"}).calendar_pages() == {1: "day", 2: "monthgrid"}


def test_a_page_background_copies_the_photo_into_the_config_folder(tmp_path, monkeypatch):
    from PIL import Image

    monkeypatch.setenv("ULANI_CONFIG_DIR", str(tmp_path / "cfg"))
    photo = tmp_path / "mine.png"
    Image.new("RGB", (1000, 600), (0, 255, 0)).save(photo)
    s = config.Settings()
    bg = config.set_background(s, 2, photo, crop=(0.0, 0.0, 0.5, 0.5))
    assert bg == config.PageBackground("page-2.jpg", (0.0, 0.0, 0.5, 0.5)) and s.backgrounds == {2: bg}
    with Image.open(tmp_path / "cfg" / "backgrounds" / "page-2.jpg") as stored:
        assert stored.size == (1000, 600)  # a copy, not a link
    config.save(s)
    assert config.load() == s
    assert json.loads(config.settings_path().read_text(encoding="utf-8"))["backgrounds"] == {
        "2": {"image": "page-2.jpg", "crop": [0.0, 0.0, 0.5, 0.5]}}
    config.clear_background(s, 2)
    assert s.backgrounds == {} and not (tmp_path / "cfg" / "backgrounds" / "page-2.jpg").exists()


def test_a_bad_crop_or_photo_changes_nothing(tmp_path, monkeypatch):
    from PIL import Image

    monkeypatch.setenv("ULANI_CONFIG_DIR", str(tmp_path / "cfg"))
    photo = tmp_path / "mine.png"
    Image.new("RGB", (1000, 600), (0, 255, 0)).save(photo)
    s = config.Settings()
    with pytest.raises(ValueError):
        config.set_background(s, 1, photo, crop=(0.0, 0.0, 1.0, 0.5))  # not 5:3
    with pytest.raises(UlaniError):
        config.set_background(s, 1, tmp_path / "missing.png")
    assert s.backgrounds == {} and not (tmp_path / "cfg" / "backgrounds").exists()
