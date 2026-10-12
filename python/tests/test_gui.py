import asyncio
import gc
import threading
import time

import pytest
from PIL import Image

tk = pytest.importorskip("tkinter")

from ulani_epaper import gui  # noqa: E402
from ulani_epaper.client import PushEvent, UploadResult  # noqa: E402
from ulani_epaper.protocol import Battery, FRAME_BYTES, UlaniError  # noqa: E402


@pytest.fixture(scope="module")
def tk_root():
    # One Tcl/Tk interpreter for the whole module: creating and destroying
    # many interpreters in one process intermittently fails on Windows with
    # "Can't find a usable init.tcl". The real app only ever creates one.
    try:
        r = tk.Tk()
    except tk.TclError as e:
        pytest.skip(f"no display for Tk: {e}")
    r.withdraw()
    yield r
    r.destroy()
    gc.collect()


@pytest.fixture
def root(tk_root):
    """A fresh window per test (App only needs what a Toplevel offers)."""
    top = tk.Toplevel(tk_root)
    top.withdraw()
    yield top
    # Let preview threads of this test finish, tear the window down, then
    # collect the App/Tile reference cycles HERE, on the main thread: if a
    # later background thread triggered that collection, PhotoImage.__del__
    # would call Tk from the wrong thread ("main thread is not in main loop").
    for t in threading.enumerate():
        if t is not threading.main_thread() and t.daemon and t.name != "ulani-ble":
            t.join(timeout=5)
    try:
        top.destroy()
    except tk.TclError:
        pass
    del top
    gc.collect()


def pump(root, until, timeout=60.0):  # Stucki previews take seconds on slow CI runners
    end = time.monotonic() + timeout
    while not until():
        if time.monotonic() > end:
            raise AssertionError("condition not reached")
        root.update()
        time.sleep(0.01)


def photo(tmp_path, name="p.png", colour="red"):
    path = tmp_path / name
    Image.new("RGB", (160, 100), colour).save(path)
    return str(path)


def make_app(root, monkeypatch, **kw):
    errors = []
    monkeypatch.setattr(gui.messagebox, "showerror", lambda title, text: errors.append(text))
    app = gui.App(root, **kw)
    return app, errors


def test_choosing_photos_builds_previews_and_enables_push(root, monkeypatch, tmp_path):
    app, _ = make_app(root, monkeypatch)
    try:
        assert str(app.push_btn.cget("state")) == "disabled"
        app.tiles[2].set_path(photo(tmp_path))
        pump(root, lambda: app.tiles[2].frame is not None)
        assert len(app.tiles[2].frame) == FRAME_BYTES
        assert str(app.push_btn.cget("state")) == "normal"
        assert set(app.frames()) == {2}
    finally:
        app.worker.close()


def test_push_sends_frames_and_shows_progress(root, monkeypatch, tmp_path):
    seen = {}

    async def fake_push(frames, progress):
        seen["frames"] = frames
        for i, slot in enumerate(sorted(frames)):
            progress(PushEvent(slot, "start", i, len(frames), 0, 10))
            progress(PushEvent(slot, "sending", i, len(frames), 5, 10))
            progress(PushEvent(slot, "done", i, len(frames), 10, 10))
        return {s: UploadResult.OK for s in frames}

    app, errors = make_app(root, monkeypatch, push_fn=fake_push)
    try:
        app.tiles[1].set_path(photo(tmp_path, "a.png", "red"))
        app.tiles[4].set_path(photo(tmp_path, "b.png", "blue"))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.push()
        pump(root, lambda: "完成" in app.summary.cget("text"))
        assert set(seen["frames"]) == {1, 4}
        assert app.tiles[1].status.cget("text") == "完成" and app.tiles[1].bar.cget("value") == 100
        assert app.tiles[2].status.cget("text") == ""
        assert not errors
    finally:
        app.worker.close()


def test_push_failure_shows_a_friendly_error(root, monkeypatch, tmp_path):
    async def failing_push(frames, progress):
        raise UlaniError("could not connect after 4 attempts: no e-paper device found")

    app, errors = make_app(root, monkeypatch, push_fn=failing_push)
    try:
        app.tiles[3].set_path(photo(tmp_path))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.push()
        pump(root, lambda: errors)
        assert "找不到裝置" in errors[0]
        assert str(app.push_btn.cget("state")) == "normal"  # can retry
    finally:
        app.worker.close()


def test_read_info_shows_battery_and_page(root, monkeypatch):
    async def fake_info():
        return {"battery": Battery(level=4, charging=False), "shown": 3}

    app, _ = make_app(root, monkeypatch, info_fn=fake_info)
    try:
        app.read_info()
        assert app.device.cget("text") == "裝置狀態：連線中…"
        pump(root, lambda: "第 3 頁" in app.device.cget("text"))
        assert app.device.cget("text") == "裝置狀態：電量 4/5，目前顯示第 3 頁"
    finally:
        app.worker.close()


def test_changing_options_recomputes_previews(root, monkeypatch, tmp_path):
    app, _ = make_app(root, monkeypatch)
    try:
        tall = tmp_path / "tall.png"
        Image.new("RGB", (100, 400), "black").save(tall)
        app.tiles[1].set_path(str(tall))
        pump(root, lambda: app.tiles[1].frame is not None)
        covered = app.tiles[1].frame
        app.fit.set("contain")
        app.rerender()
        pump(root, lambda: app.tiles[1].frame is not None and app.tiles[1].frame != covered)
        assert app.tiles[1].frame[:10] == b"\x11" * 10  # contain: white margin at the left edge
    finally:
        app.worker.close()


def test_unreadable_file_is_reported_briefly_on_the_tile(root, monkeypatch, tmp_path):
    deep = tmp_path / ("a-very-long-folder-name-" * 6)
    deep.mkdir()
    bad = deep / "notes.txt"
    bad.write_text("not an image")
    app, _ = make_app(root, monkeypatch)
    try:
        app.tiles[1].set_path(str(bad))
        pump(root, lambda: "無法讀取" in app.tiles[1].status.cget("text"))
        text = app.tiles[1].status.cget("text")
        assert "notes.txt" in text and str(deep) not in text  # basename only, no long path
        assert int(app.tiles[1].status.cget("wraplength")) > 0
        assert app.tiles[1].path is None
        assert str(app.push_btn.cget("state")) == "disabled"
    finally:
        app.worker.close()


@pytest.mark.parametrize("screen_height", [768, 800, 900])
def test_window_fits_small_laptop_screens(root, monkeypatch, screen_height):
    # work area = screen - taskbar (48) - title bar (~31)
    app, _ = make_app(root, monkeypatch, thumb=gui.thumb_size(screen_height))
    try:
        root.update_idletasks()
        assert root.winfo_reqheight() <= screen_height - 48 - 31
    finally:
        app.worker.close()


def test_thumbnails_use_full_size_on_big_screens():
    assert gui.thumb_size(1440) == gui.THUMB


def test_push_button_bar_is_laid_out_before_the_page_grid(root, monkeypatch):
    # packed first with side="bottom": if the window is too short, the grid is
    # clipped, never the push button
    app, _ = make_app(root, monkeypatch)
    try:
        bar = app.push_btn.master
        assert bar.pack_info()["side"] == "bottom"
        slaves = root.pack_slaves()
        grid = app.tiles[1].box.master
        assert slaves.index(bar) < slaves.index(grid)
    finally:
        app.worker.close()


def test_status_line_and_preview_caption_call_the_hardware_a_device(root, monkeypatch, tmp_path):
    app, _ = make_app(root, monkeypatch)
    try:
        assert app.device.cget("text").startswith("裝置狀態")
        assert app.device.cget("text") == "裝置狀態：尚未讀取"
        app.tiles[1].set_path(photo(tmp_path))
        pump(root, lambda: app.tiles[1].frame is not None)
        assert app.tiles[1].status.cget("text") == "預覽為裝置實際顯示的 7 色效果"
    finally:
        app.worker.close()


def test_window_title_and_push_button_name_the_app(root, monkeypatch):
    app, _ = make_app(root, monkeypatch)
    try:
        assert root.title() == "Paperhue"
        assert app.push_btn.cget("text") == "推送到裝置"
        assert "「推送到裝置」" in app.summary.cget("text")
    finally:
        app.worker.close()


def test_options_are_locked_during_a_push(root, monkeypatch, tmp_path):
    release = threading.Event()

    async def slow_push(frames, progress):
        while not release.is_set():
            await asyncio.sleep(0.01)
        return {s: UploadResult.OK for s in frames}

    app, _ = make_app(root, monkeypatch, push_fn=slow_push)
    try:
        app.tiles[1].set_path(photo(tmp_path))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.push()
        root.update()
        assert {str(w.cget("state")) for w in app.option_widgets} == {"disabled"}
        release.set()
        pump(root, lambda: "完成" in app.summary.cget("text"))
        assert {str(w.cget("state")) for w in app.option_widgets} == {"normal"}
    finally:
        app.worker.close()


def test_failed_push_marks_every_unfinished_page(root, monkeypatch, tmp_path):
    from ulani_epaper.client import DeviceBusy

    async def push_then_fail(frames, progress):
        progress(PushEvent(1, "start", 0, 2, 0, 10))
        progress(PushEvent(1, "done", 0, 2, 10, 10))
        progress(PushEvent(2, "start", 1, 2, 0, 10))  # waits for the header, then gives up
        raise DeviceBusy("the device did not accept an image for page 2 within 60s")

    app, errors = make_app(root, monkeypatch, push_fn=push_then_fail)
    try:
        app.tiles[1].set_path(photo(tmp_path, "a.png"))
        app.tiles[2].set_path(photo(tmp_path, "b.png"))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.push()
        pump(root, lambda: errors)
        assert app.tiles[1].status.cget("text") == "完成"
        assert app.tiles[2].status.cget("text") == "未完成"
        assert "沒有回應" in errors[0]
    finally:
        app.worker.close()


@pytest.mark.parametrize("error, phrase", [
    ("busy", "沒有回應"),
    ("noreply", "沒有回應"),
    ("failed", "資料有誤"),
    ("bleak", "藍牙連線中斷"),
    ("auth", "尚未與這台電腦配對"),
    ("notfound", "找不到裝置"),
    ("notfound-bare", "找不到裝置"),
])
def test_friendly_explains_each_kind_of_error(error, phrase):
    from bleak.exc import BleakError

    from ulani_epaper.client import DeviceBusy, NoReply, UploadFailed

    errors = {
        "busy": DeviceBusy("did not accept"),
        "noreply": NoReply("no reply to opcode 0x02 within 90s"),
        "failed": UploadFailed("page 1: device reported failure: 02 01"),
        "bleak": BleakError("Not connected"),
        # connect() wraps the bonding error, which must still be recognised
        "auth": UlaniError("could not connect after 4 attempts: BleakError('Protocol Error 0x05: "
                           "Insufficient Authentication')"),
        "notfound": UlaniError("could not connect after 4 attempts: UlaniError('no e-paper device found')"),
        # client.find's own message, as the relay passes it on
        "notfound-bare": UlaniError("no e-paper device found (is Bluetooth on and the device nearby?)"),
    }
    text = gui.friendly(errors[error])
    assert phrase in text
    assert "月曆" not in text  # the hardware is called 裝置 everywhere


def test_closing_during_a_status_read_does_not_ask(root, monkeypatch):
    release = threading.Event()
    asked = []

    async def slow_info():
        while not release.is_set():
            await asyncio.sleep(0.01)
        return {"battery": Battery(level=4, charging=False), "shown": 1}

    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a: asked.append(a) or True)
    app, _ = make_app(root, monkeypatch, info_fn=slow_info)
    app.read_info()
    root.update()
    release.set()
    app.close()  # destroys the window
    assert asked == []


def test_device_line_does_not_stay_on_connecting_after_a_push(root, monkeypatch, tmp_path):
    async def ok_push(frames, progress):
        return {s: UploadResult.OK for s in frames}

    app, _ = make_app(root, monkeypatch, push_fn=ok_push)
    try:
        app.device.configure(text="裝置狀態：連不上")
        app.tiles[1].set_path(photo(tmp_path))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.push()
        pump(root, lambda: "完成" in app.summary.cget("text"))
        assert "剛完成推送" in app.device.cget("text")
    finally:
        app.worker.close()
