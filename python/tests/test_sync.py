import asyncio
from datetime import date, datetime, timedelta, timezone

import pytest
from PIL import Image

from ulani_epaper import image as im
from ulani_epaper import sync
from ulani_epaper.agenda import AgendaData, Task
from ulani_epaper.client import UploadResult
from ulani_epaper.config import Feed, Settings

TPE = timezone(timedelta(hours=8))
NOW = datetime(2026, 10, 12, 6, 0, 30, tzinfo=TPE)
DATA = AgendaData(tasks=(Task("x"),), fetched_at=NOW)


def solid(colour):
    def render(data, today, tz):
        assert (data, today, tz) == (DATA, date(2026, 10, 12), TPE)
        return Image.new("RGB", (800, 480), im.COLOURS[colour].rgb)
    return render


RENDERERS = {"month": solid("red"), "agenda": solid("blue"), "todo": solid("green")}


class Fakes:
    def __init__(self, monkeypatch):
        self.fetched, self.pushed = [], []

        def fetch(feeds, today, tz, now, secrets=None, download=None):
            self.fetched.append((feeds, today, tz, now, secrets))
            return DATA

        monkeypatch.setattr(sync.feeds, "fetch", fetch)

    async def push(self, frames, *, address=None, progress=None, **kw):
        self.pushed.append((dict(frames), address))
        return {slot: UploadResult.OK for slot in frames}


def run(**kw):
    return asyncio.run(sync.sync(now=NOW, renderers=RENDERERS, **kw))


def test_renders_the_calendar_pages_and_pushes_them_in_one_go(monkeypatch):
    f = Fakes(monkeypatch)
    s = Settings(pages={1: "month", 2: "photo", 3: "todo", 4: "agenda"}, feeds=[Feed("p1", "個人")],
                 address="AA:BB")
    report = run(settings=s, push=f.push, secrets="store")
    assert f.fetched == [([Feed("p1", "個人")], date(2026, 10, 12), TPE, NOW, "store")]
    (frames, address), = f.pushed
    assert sorted(frames) == [1, 3, 4] and address == "AA:BB"  # the photo page is left alone
    assert frames[1] == im.encode(Image.new("RGB", (800, 480), (255, 0, 0)), dither=False)
    assert set(im.unpack(frames[3])) == {2} and set(im.unpack(frames[4])) == {3}  # green, blue
    assert report.results == {1: UploadResult.OK, 3: UploadResult.OK, 4: UploadResult.OK}
    assert report.pages == {1: "month", 3: "todo", 4: "agenda"} and report.tasks == 1 and report.events == 0


def test_drawings_are_handed_over_before_the_push(monkeypatch):
    f = Fakes(monkeypatch)
    order = []

    async def push(frames, **kw):
        order.append("push")
        return {slot: UploadResult.OK for slot in frames}

    run(settings=Settings(), push=push, on_rendered=lambda images: order.append(sorted(images)))
    assert order == [[1, 2, 3], "push"]


def test_dry_run_renders_without_pushing(monkeypatch):
    f = Fakes(monkeypatch)
    report = run(settings=Settings(), push=f.push, dry_run=True)
    assert f.pushed == [] and report.results is None
    assert sorted(report.images) == [1, 2, 3]
    assert report.images[1].size == (800, 480)


def test_nothing_to_do_without_calendar_pages(monkeypatch):
    f = Fakes(monkeypatch)
    report = run(settings=Settings(pages={1: "photo", 2: "photo", 3: "photo", 4: "photo"}), push=f.push)
    assert f.fetched == [] and f.pushed == [] and report.pages == {}


def test_no_push_when_fetching_fails(monkeypatch):
    f = Fakes(monkeypatch)

    def offline(*a, **kw):
        raise sync.feeds.FeedError("個人：無法連線到 calendar.google.com（gaierror）")

    monkeypatch.setattr(sync.feeds, "fetch", offline)
    with pytest.raises(sync.feeds.FeedError):
        run(settings=Settings(), push=f.push)
    assert f.pushed == []


def test_rendered_pages_must_use_only_the_panel_colours(monkeypatch):
    f = Fakes(monkeypatch)
    grey = {"month": lambda d, t, z: Image.new("RGB", (800, 480), (128, 128, 128))}
    with pytest.raises(ValueError, match="page 1"):
        asyncio.run(sync.sync(settings=Settings(pages={1: "month", 2: "photo", 3: "photo", 4: "photo"}),
                              now=NOW, renderers=grey, push=f.push))
    assert f.pushed == []


def test_uses_the_local_time_zone_by_default(monkeypatch):
    f = Fakes(monkeypatch)
    monkeypatch.setattr(sync.feeds, "fetch",
                        lambda feeds, today, tz, now, secrets=None, download=None:
                        f.fetched.append((today, tz, now)) or AgendaData())
    any_page = {"todo": lambda d, t, z: Image.new("RGB", (800, 480), "white")}
    asyncio.run(sync.sync(settings=Settings(pages={1: "todo", 2: "photo", 3: "photo", 4: "photo"}),
                          renderers=any_page, push=f.push))
    (today, tz, now), = f.fetched
    assert tz is sync.LOCAL and now.tzinfo is sync.LOCAL and today == now.date()
