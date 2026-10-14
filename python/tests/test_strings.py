import re
import string

import pytest

from ulani_epaper import config, image, strings
from ulani_epaper.gui import COLOUR_KEYS, GRAIN_KEYS
from ulani_epaper.strings import system_language as real_system_language  # before conftest replaces it

CJK = re.compile(r"[\u3000-\u9fff\uff00-\uffef]")
#: English texts that may say "calendar": they are about calendar data (feeds, events), never the device
CALENDAR_DATA_KEYS = {
    "feeds_missing_pkg", "feeds_none", "feeds_named", "feeds_btn", "feeds_title", "feeds_help", "feed_new_title",
    "calendar_tile_name", "sync_reading", "sync_rendered", "tile_reading", "drop_partial", "schedule_prompt",
    "fe_scheme", "fe_big", "fe_not_ical", "fe_none", "hint_no_feeds", "hint_feed_error",
    "summary_idle", "sj_no_pages", "push_no_calendars",
}


def placeholders(text):
    return {name for _, name, _, _ in string.Formatter().parse(text) if name is not None}


def test_every_key_in_both_languages_with_same_placeholders():
    assert strings.LANGUAGES == ("zh", "en")
    for key, texts in strings.STRINGS.items():
        assert set(texts) == {"zh", "en"}, key
        assert texts["zh"] and texts["en"], key
        assert placeholders(texts["zh"]) == placeholders(texts["en"]), key


def test_english_is_english_and_never_calls_the_hardware_a_calendar():
    for key, texts in strings.STRINGS.items():
        assert key == "language_toggle" or not CJK.search(texts["en"]), key
        if "calendar" in texts["en"].lower():
            assert key in CALENDAR_DATA_KEYS, f"{key}: {texts['en']!r}"


def test_t_follows_the_chosen_language_and_formats():
    assert strings.language() == "zh" and strings.t("page_title", n=2) == "第 2 頁"
    strings.set_language("en")
    assert strings.language() == "en" and strings.t("page_title", n=2) == "Page 2"
    assert [strings.page_name(k) for k in config.PAGE_KINDS] == [
        "Photo", "Today + month", "Today + week", "To-do", "Day", "Month", "Notes board", "Big message", "Card"]
    with pytest.raises(ValueError):
        strings.set_language("fr")
    assert strings.language() == "en"


def test_every_grain_colour_choice_and_page_kind_has_a_text():
    assert set(GRAIN_KEYS) == set(image.GRAIN) and list(COLOUR_KEYS) == list(image.COLOUR_CHOICES)
    for key in [*GRAIN_KEYS.values(), *COLOUR_KEYS.values(), *("page_" + k for k in config.PAGE_KINDS)]:
        assert key in strings.STRINGS
    assert [strings.STRINGS[key]["zh"] for key in COLOUR_KEYS.values()] == list(image.COLOUR_CHOICES)
    assert [strings.STRINGS[key]["en"] for key in ("colours_label", *COLOUR_KEYS.values())] == [
        "Colours", "Natural", "Classic"]
    assert strings.STRINGS["colours_label"]["zh"] == strings.STRINGS["colour_label"]["zh"] == "顏色"


@pytest.mark.parametrize("locale_name, expected", [("zh_TW", "zh"), ("zh_Hant_TW", "zh"), ("en_US", "en"),
                                                     ("ja_JP", "en"), (None, "en")])
def test_system_language_is_chinese_only_for_a_chinese_locale(monkeypatch, locale_name, expected):
    monkeypatch.setattr(strings.sys, "platform", "linux")
    monkeypatch.setattr(strings.locale, "getlocale", lambda *a: (locale_name, "UTF-8"))
    assert real_system_language() == expected


def test_the_schedule_prompt_suggests_times_without_filling_any_in():
    assert "例如早上一次、下午一次" in strings.STRINGS["schedule_prompt"]["zh"]
    assert "for example one in the morning and one in the afternoon" in strings.STRINGS["schedule_prompt"]["en"]
    assert config.DEFAULT_TIMES == []
