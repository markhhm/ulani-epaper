import asyncio
from datetime import date, datetime, timedelta, timezone

import pytest
from PIL import Image

from ulani_epaper import image as im
from ulani_epaper import sync
from ulani_epaper.agenda import AgendaData, Task
from ulani_epaper.client import UploadResult
from ulani_epaper.config import Feed, Settings
from ulani_epaper.notes import Note
from ulani_epaper.protocol import UlaniError

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


# --- message board pages -------------------------------------------------------------

NOTES = [Note("a1b2c3d4", "晚餐在冰箱", "2026-10-12T14:03:00+08:00", "yellow")]


def board_solid(colour):
    def render(notes, tz):
        assert notes == NOTES and tz == TPE
        return Image.new("RGB", (800, 480), im.COLOURS[colour].rgb)
    return render


BOARD_RENDERERS = {"board": board_solid("orange"), "message": board_solid("red")}


class PushWithShow(Fakes):
    async def push(self, frames, *, address=None, progress=None, show="not given", **kw):
        self.pushed.append((dict(frames), show))
        return {slot: UploadResult.OK for slot in frames}


def test_a_board_only_setup_needs_no_feeds(monkeypatch):
    f = PushWithShow(monkeypatch)
    s = Settings(pages={1: "photo", 2: "board", 3: "photo", 4: "message"})  # no feeds at all
    report = asyncio.run(sync.sync(settings=s, now=NOW, renderers=BOARD_RENDERERS, push=f.push, notes=NOTES))
    assert f.fetched == []  # feeds.fetch would raise NoFeeds
    (frames, show), = f.pushed
    assert sorted(frames) == [2, 4] and show == "not given"  # a sync never switches the display
    assert set(im.unpack(frames[2])) == {6} and set(im.unpack(frames[4])) == {4}  # orange, red
    assert report.pages == {2: "board", 4: "message"} and report.notes == 1 and report.events == 0


def test_a_mixed_setup_fetches_the_feeds_once_and_reads_the_saved_notes(monkeypatch):
    from ulani_epaper import notes

    f = Fakes(monkeypatch)
    saved = notes.add("晚餐在冰箱", now=datetime(2026, 10, 12, 14, 3, tzinfo=TPE))
    drawn = []

    def board(notes_, tz):
        drawn.append(list(notes_))
        return Image.new("RGB", (800, 480), "white")

    s = Settings(pages={1: "month", 2: "board", 3: "todo", 4: "photo"}, feeds=[Feed("p1", "個人")])
    report = asyncio.run(sync.sync(settings=s, now=NOW, push=f.push, renderers={**RENDERERS, "board": board}))
    assert len(f.fetched) == 1 and drawn == [[saved]]
    (frames, _), = f.pushed
    assert sorted(frames) == [1, 2, 3] and report.notes == 1 and report.tasks == 1


def test_sync_draws_the_real_board_pages(monkeypatch):
    f = Fakes(monkeypatch)
    s = Settings(pages={1: "board", 2: "message", 3: "photo", 4: "photo"})
    report = asyncio.run(sync.sync(settings=s, now=NOW, push=f.push, notes=NOTES, dry_run=True))
    assert sorted(report.images) == [1, 2] and f.pushed == []


def test_a_damaged_notes_file_stops_the_sync_before_pushing(monkeypatch):
    from ulani_epaper import notes

    f = Fakes(monkeypatch)
    notes.notes_path().parent.mkdir(parents=True, exist_ok=True)
    notes.notes_path().write_text("{broken", encoding="utf-8")
    with pytest.raises(UlaniError, match="notes"):
        run(settings=Settings(pages={1: "month", 2: "board", 3: "photo", 4: "photo"}), push=f.push)
    assert f.pushed == [] and notes.notes_path().read_text(encoding="utf-8") == "{broken"


def post(f, pages, **kw):
    return asyncio.run(sync.post(Settings(pages=pages, address="AA:BB"), push=f.push, notes=NOTES, tz=TPE,
                                 renderers=BOARD_RENDERERS, **kw))


@pytest.mark.parametrize("pages, show, target", [
    ({1: "month", 2: "board", 3: "message", 4: "board"}, "auto", 3),  # the big message first
    ({1: "month", 2: "board", 3: "photo", 4: "board"}, "auto", 2),
    ({1: "month", 2: "board", 3: "message", 4: "board"}, "board", 2),
    ({1: "message", 2: "board", 3: "message", 4: "board"}, "message", 1),
    ({1: "month", 2: "board", 3: "photo", 4: "photo"}, "message", 2),  # none of that kind: the auto choice
    ({1: "month", 2: "board", 3: "message", 4: "board"}, "none", None),
])
def test_post_pushes_only_the_board_pages_and_switches(monkeypatch, pages, show, target):
    f = PushWithShow(monkeypatch)
    report = post(f, pages, show=show)
    (frames, pushed_show), = f.pushed
    board_slots = sorted(s for s, k in pages.items() if k in ("board", "message"))
    assert sorted(frames) == board_slots and pushed_show == target
    assert f.fetched == []  # works offline
    assert report.show == target and report.pages == {s: pages[s] for s in board_slots}
    assert report.results == {s: UploadResult.OK for s in board_slots} and report.notes == 1


def test_post_without_a_board_page_explains_what_to_do(monkeypatch):
    f = PushWithShow(monkeypatch)
    with pytest.raises(UlaniError) as info:
        post(f, {1: "month", 2: "agenda", 3: "todo", 4: "photo"})
    assert str(info.value) == "沒有留言頁：先把某一頁設為「留言板」或「大字留言」"
    assert f.pushed == []


def test_post_rejects_an_unknown_show_mode(monkeypatch):
    f = PushWithShow(monkeypatch)
    with pytest.raises(ValueError, match="auto, board, message or none"):
        post(f, {1: "board", 2: "photo", 3: "photo", 4: "photo"}, show="all")
    assert f.pushed == []


def test_post_dry_run_draws_from_the_saved_notes(monkeypatch):
    from ulani_epaper import notes

    f = PushWithShow(monkeypatch)
    notes.add("我去接小孩", "red", now=datetime(2026, 10, 12, 16, 45, tzinfo=TPE))
    seen = []
    report = asyncio.run(sync.post(Settings(pages={1: "board", 2: "photo", 3: "message", 4: "photo"}),
                                   push=f.push, dry_run=True, on_rendered=seen.append))
    assert f.pushed == [] and report.results is None and report.show == 3
    assert sorted(report.images) == [1, 3] and seen and sorted(seen[0]) == [1, 3]
    assert (255, 0, 0) in {c for _, c in report.images[3].getcolors(1 << 20)}  # the red note, drawn for real
