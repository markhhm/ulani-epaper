"""Pushing cards to the card pages: which page a card goes to, preloading several (no Bluetooth: connect is faked)."""

import asyncio
from contextlib import asynccontextmanager

import pytest

from ulani_epaper import image as im
from ulani_epaper import layouts, sync
from ulani_epaper.cards import Background, Card, TextBox
from ulani_epaper.client import UploadResult
from ulani_epaper.config import Settings
from ulani_epaper.protocol import UlaniError

AWAY = Card("a1b2c3d4", Background("yellow"), (TextBox("暫離", (0.1, 0.2, 0.8, 0.3)),))
MEETING = Card("b1b2c3d4", Background("red"), (TextBox("開會中", (0.1, 0.2, 0.8, 0.3), color="white"),))
LUNCH = Card("c1b2c3d4", Background("green"))

PAGES = {1: "month", 2: "card", 3: "card", 4: "photo"}


def frame(card):
    return im.encode(layouts.render_card(card), dither=False)


class FakeDevice:
    """What the device shows, and every push_pages call it receives."""

    def __init__(self, shown):
        self.shown, self.calls, self.connections = shown, [], 0

    @asynccontextmanager
    async def connect(self, address=None, **kw):
        self.connections += 1
        self.address = address
        yield self

    async def current_slot(self):
        return self.shown, 0

    async def push_pages(self, frames, progress=None, show=None):
        self.calls.append((dict(frames), show))
        return {slot: UploadResult.OK for slot in frames}


def push(settings, card, shown):
    device = FakeDevice(shown)
    report = asyncio.run(sync.push_card(settings, card, connect=device.connect))
    return device, report


def test_replaces_the_card_page_on_screen():
    device, report = push(Settings(pages=PAGES, address="AA:BB"), AWAY, shown=3)
    assert device.calls == [({3: frame(AWAY)}, 3)] and device.address == "AA:BB"
    assert report.pages == {3: "card"} and report.show == 3 and report.results == {3: UploadResult.OK}


def test_goes_to_the_lowest_card_page_when_a_card_page_is_not_on_screen():
    device, report = push(Settings(pages=PAGES), AWAY, shown=1)
    assert device.calls == [({2: frame(AWAY)}, 2)] and report.show == 2


def test_a_card_already_on_a_page_is_just_shown():
    settings = Settings(pages=PAGES)
    asyncio.run(sync.preload_cards(settings, [AWAY, MEETING], connect=FakeDevice(1).connect))
    device, report = push(settings, MEETING, shown=2)  # MEETING sits on page 3, page 2 is on screen
    assert device.calls == [({3: frame(MEETING)}, 3)] and report.show == 3  # the device skips the unchanged image
    assert settings.card_pages == {2: sync.frame_hash(frame(AWAY)), 3: sync.frame_hash(frame(MEETING))}


def test_an_edited_card_is_not_taken_for_the_preloaded_one():
    settings = Settings(pages=PAGES)
    asyncio.run(sync.preload_cards(settings, [AWAY, MEETING], connect=FakeDevice(1).connect))
    edited = Card(MEETING.id, Background("blue"), MEETING.texts)
    device, report = push(settings, edited, shown=2)
    assert report.show == 2  # it is not on the device: the card page on screen is replaced


def test_without_a_card_page_it_says_which_page_to_offer():
    device = FakeDevice(1)
    with pytest.raises(sync.NoCardPage) as info:
        asyncio.run(sync.push_card(Settings(pages={1: "month", 2: "agenda", 3: "todo", 4: "photo"}), AWAY,
                                   connect=device.connect))
    assert isinstance(info.value, UlaniError) and info.value.suggested_slot == 4  # the photo page
    assert str(info.value) == "沒有牌卡頁：先把某一頁設為「牌卡」" and device.connections == 0
    with pytest.raises(sync.NoCardPage) as info:
        asyncio.run(sync.push_card(Settings(pages={1: "photo", 2: "month", 3: "board", 4: "todo"}), AWAY,
                                   connect=device.connect))
    assert info.value.suggested_slot == 1
    with pytest.raises(sync.NoCardPage) as info:
        asyncio.run(sync.push_card(Settings(pages={1: "month", 2: "agenda", 3: "todo", 4: "board"}), AWAY,
                                   connect=device.connect))
    assert info.value.suggested_slot == 4  # no photo page: page 4


def test_preloading_fills_the_card_pages_in_one_connection_without_switching():
    settings = Settings(pages={1: "month", 2: "card", 3: "card", 4: "card"})
    device = FakeDevice(1)
    report = asyncio.run(sync.preload_cards(settings, [AWAY, MEETING, LUNCH], connect=device.connect))
    assert device.connections == 1
    assert device.calls == [({2: frame(AWAY), 3: frame(MEETING), 4: frame(LUNCH)}, None)]
    assert report.pages == {2: "card", 3: "card", 4: "card"} and report.show is None
    assert settings.card_pages == {2: sync.frame_hash(frame(AWAY)), 3: sync.frame_hash(frame(MEETING)),
                                   4: sync.frame_hash(frame(LUNCH))}


def test_preloading_more_cards_than_card_pages_is_refused_before_connecting():
    device = FakeDevice(1)
    with pytest.raises(UlaniError, match="3.*2"):
        asyncio.run(sync.preload_cards(Settings(pages=PAGES), [AWAY, MEETING, LUNCH], connect=device.connect))
    with pytest.raises(sync.NoCardPage):
        asyncio.run(sync.preload_cards(Settings(), [AWAY], connect=device.connect))
    assert device.connections == 0


def test_a_page_that_stopped_being_a_card_page_is_forgotten():
    settings = Settings(pages={1: "month", 2: "photo", 3: "card", 4: "photo"}, card_pages={2: "stale", 3: "old"})
    push(settings, AWAY, shown=3)
    assert settings.card_pages == {3: sync.frame_hash(frame(AWAY))}




def test_cards_are_drawn_with_the_saved_grain_and_colours(monkeypatch):
    drawn = []
    real = layouts.render_card

    def spy(card, backgrounds=None, strength=1.0, colours="natural"):
        drawn.append((strength, colours))
        return real(card, backgrounds, strength, colours)

    monkeypatch.setattr(layouts, "render_card", spy)
    push(Settings(pages=PAGES, grain=0.65, colours="classic"), AWAY, shown=2)
    asyncio.run(sync.preload_cards(Settings(pages=PAGES, grain=0.8), [AWAY, MEETING], connect=FakeDevice(1).connect))
    push(Settings(pages=PAGES, colours="bright"), MEETING, shown=3)
    assert drawn == [(0.65, "classic"), (0.8, "natural"), (0.8, "natural"), (1.0, "bright")]
