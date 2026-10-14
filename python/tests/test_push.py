import asyncio
from contextlib import asynccontextmanager

import pytest
from PIL import Image

from ulani_epaper import cli, push
from ulani_epaper.client import PushEvent, UploadResult
from ulani_epaper.protocol import FRAME_BYTES


def _img(colour):
    return Image.new("RGB", (64, 48), colour)


def test_prepare_maps_a_sequence_to_slots_and_skips_none():
    frames = push.prepare([_img("red"), None, _img("blue")])
    assert sorted(frames) == [1, 3]
    assert all(len(f) == FRAME_BYTES for f in frames.values())


def test_prepare_accepts_a_mapping_and_paths(tmp_path):
    path = tmp_path / "a.png"
    _img("green").save(path)
    frames = push.prepare({4: path, 2: str(path)})
    assert sorted(frames) == [2, 4]
    assert frames[2] == frames[4]


def test_prepare_accepts_a_single_image(tmp_path):
    path = tmp_path / "solo.png"
    _img("green").save(path)
    for single in (str(path), path, _img("green")):
        assert sorted(push.prepare(single)) == [1]


@pytest.mark.parametrize("images", [[_img("red")] * 5, {0: _img("red")}, {5: _img("red")}, []])
def test_prepare_rejects_bad_input(images):
    with pytest.raises(ValueError):
        push.prepare(images)


def test_prepare_uses_cover_by_default():
    # a tall image: cover crops it to fill the frame, contain would letterbox in white
    tall = Image.new("RGB", (100, 400), "black")
    frame = push.prepare([tall])[1]
    assert frame[:400] == b"\x00" * 400  # first row is all black, no white border


class FakeCal:
    def __init__(self):
        self.pushed = None
        self.show = "not given"

    async def push_pages(self, frames, progress=None, busy_timeout=60.0, show=None):
        self.pushed, self.show = frames, show
        for i, slot in enumerate(sorted(frames)):
            progress(PushEvent(slot, "start", i, len(frames), 0, len(frames[slot])))
            progress(PushEvent(slot, "sending", i, len(frames), len(frames[slot]), len(frames[slot])))
            progress(PushEvent(slot, "done", i, len(frames), len(frames[slot]), len(frames[slot])))
        return {s: UploadResult.OK for s in frames}


def _fake_connect(cal, seen):
    @asynccontextmanager
    async def connect(address=None, **kwargs):
        seen.update(address=address, **kwargs)
        yield cal

    return connect


def test_push_images_encodes_connects_and_pushes(monkeypatch):
    cal, seen, events = FakeCal(), {}, []
    monkeypatch.setattr(push, "connect", _fake_connect(cal, seen))
    results = asyncio.run(push.push_images([_img("red"), _img("blue")], address="AA:BB", progress=events.append))
    assert results == {1: UploadResult.OK, 2: UploadResult.OK}
    assert sorted(cal.pushed) == [1, 2] and seen["address"] == "AA:BB"
    assert [e.phase for e in events].count("done") == 2


def test_prepare_and_push_images_dither_in_the_chosen_colours(monkeypatch):
    chosen, real = [], push.image.encode
    monkeypatch.setattr(push.image, "encode", lambda *a, **kw: chosen.append(kw["colours"]) or real(*a, **kw))
    monkeypatch.setattr(push, "connect", _fake_connect(FakeCal(), {}))
    flat = _img("white")  # white stays white either way: quick
    assert push.prepare([flat], colours="classic") == push.prepare([flat])
    asyncio.run(push.push_images([flat], colours="classic", progress=lambda e: None))
    assert chosen == ["classic", "natural", "classic"]


def test_push_frames_passes_the_page_to_show(monkeypatch):
    cal, seen = FakeCal(), {}
    monkeypatch.setattr(push, "connect", _fake_connect(cal, seen))
    frames = push.prepare([_img("red")])
    assert asyncio.run(push.push_frames(frames, show=3, progress=lambda e: None)) == {1: UploadResult.OK}
    assert cal.show == 3 and "show" not in seen  # for push_pages, not for connect()
    asyncio.run(push.push_frames(frames, progress=lambda e: None))
    assert cal.show is None


def test_cli_push_dry_run_saves_one_preview_per_page(tmp_path):
    srcs = []
    for i, colour in enumerate(["red", "green", "blue"]):
        srcs.append(tmp_path / f"{i}.png")
        _img(colour).save(srcs[-1])
    out = tmp_path / "previews"
    assert cli.main(["push", *map(str, srcs), "--dry-run", "--save-preview", str(out)]) == 0
    assert sorted(p.name for p in out.iterdir()) == ["page1.png", "page2.png", "page3.png"]


def test_cli_push_reports_each_page(tmp_path, monkeypatch, capsys):
    cal = FakeCal()
    monkeypatch.setattr(push, "connect", _fake_connect(cal, {}))
    srcs = []
    for i in range(4):
        srcs.append(tmp_path / f"{i}.png")
        _img("red").save(srcs[-1])
    assert cli.main(["push", *map(str, srcs)]) == 0
    out = capsys.readouterr().out
    for slot in range(1, 5):
        assert f"page {slot}" in out
    assert sorted(cal.pushed) == [1, 2, 3, 4]


def test_cli_push_rejects_more_than_four_images(tmp_path):
    src = tmp_path / "a.png"
    _img("red").save(src)
    assert cli.main(["push", *[str(src)] * 5, "--dry-run"]) == 1
