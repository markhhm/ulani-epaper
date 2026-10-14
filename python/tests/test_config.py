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


def test_the_card_chosen_for_each_card_page_is_kept(tmp_path):
    path = tmp_path / "s.json"
    s = config.Settings(pages={1: "month", 2: "card", 3: "card", 4: "photo"},
                        card_choice={2: "a1b2c3d4", 3: "b1b2c3d4"})
    config.save(s, path)
    assert config.load(path).card_choice == {2: "a1b2c3d4", 3: "b1b2c3d4"}
    assert json.loads(path.read_text(encoding="utf-8"))["card_choice"] == {"2": "a1b2c3d4", "3": "b1b2c3d4"}
    assert config.Settings().card_choice == {}
    s.pages[3] = "photo"  # no longer a card page: its card drops out
    config.save(s, path)
    assert s.card_choice == {2: "a1b2c3d4"} and config.load(path).card_choice == {2: "a1b2c3d4"}
    path.write_text('{"pages": {"2": "card", "3": "todo"}, "card_choice": {"2": "a1b2c3d4", "3": "b1b2c3d4"}}',
                    encoding="utf-8")  # changed elsewhere (the command line)
    assert config.load(path).card_choice == {2: "a1b2c3d4"}
    for bad in ({5: "a1b2c3d4"}, {2: 7}):
        with pytest.raises(ValueError, match="1-4"):
            config.Settings(pages={2: "card"}, card_choice=bad).validate()


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


def test_the_grain_is_saved_with_the_settings(tmp_path):
    assert config.Settings().grain == 1.0
    config.save(config.Settings(grain=0.65), tmp_path / "s.json")
    assert config.load(tmp_path / "s.json").grain == 0.65
    for bad in (0, 1.5, -0.2):
        with pytest.raises(ValueError, match="grain"):
            config.Settings(grain=bad).validate()


def test_the_colours_are_saved_with_the_settings(tmp_path):
    path = tmp_path / "s.json"
    assert (config.Settings().colours, config.Settings().grain) == ("natural", 1.0)
    config.save(config.Settings(colours="classic", grain=0.8), path)
    assert json.loads(path.read_text(encoding="utf-8"))["colours"] == "classic"
    loaded = config.load(path)
    assert (loaded.colours, loaded.grain) == ("classic", 0.8)
    config.save(config.Settings(colours="natural", grain=0.5), path)  # 自然 with a softer grain, chosen afterwards
    loaded = config.load(path)
    assert (loaded.colours, loaded.grain) == ("natural", 0.5)
    for bad in ("Natural", "", None, "stucki", 1):
        with pytest.raises(ValueError, match="colours"):
            config.Settings(colours=bad).validate()
    path.write_text('{"colours": "vivid", "grain": 0.8}', encoding="utf-8")
    with pytest.raises(UlaniError, match="colours"):
        config.load(path)


@pytest.mark.parametrize("grain", ["0.65", "0.5", "1.0", "5", '"soft"'])
def test_settings_saved_without_colours_load_as_natural_with_standard_grain(tmp_path, grain):
    path = tmp_path / "s.json"
    path.write_text('{"pages": {"4": "photo"}, "grain": %s}' % grain, encoding="utf-8")  # saved before 0.4
    loaded = config.load(path)
    assert (loaded.colours, loaded.grain) == ("natural", 1.0)  # once: whatever grain it held
    loaded.grain = 0.8
    config.save(loaded, path)
    assert (config.load(path).colours, config.load(path).grain) == ("natural", 0.8)  # from now on as saved


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
