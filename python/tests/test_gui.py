import asyncio
import gc
import io
import struct
import sys
import threading
import time
from importlib import resources

import pytest
from PIL import Image

tk = pytest.importorskip("tkinter")

from ulani_epaper import config, feeds, gui, ical, syncjob  # noqa: E402
from ulani_epaper.agenda import Task  # noqa: E402
from ulani_epaper.client import PushEvent, UploadResult  # noqa: E402
from ulani_epaper.feeds import FeedError, NoFeeds  # noqa: E402
from ulani_epaper.protocol import Battery, FRAME_BYTES, UlaniError  # noqa: E402
from ulani_epaper.sync import SyncReport  # noqa: E402


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


ALL_PHOTOS = {1: "photo", 2: "photo", 3: "photo", 4: "photo"}
ONE_FEED = (config.Feed("p1", "個人", "blue"),)
SECRET = "https://calendar.google.com/calendar/ical/me%40gmail.com/private-0123abcd/basic.ics"


class MemorySecrets(feeds.SecretStore):
    def __init__(self, values=None):
        self.values = dict(values or {})

    def get(self, feed_id):
        return self.values.get(feed_id)

    def set(self, feed_id, url, user="", password=""):
        self.values[feed_id] = {"url": url, "user": user, "password": password}

    def delete(self, feed_id):
        self.values.pop(feed_id, None)


def make_app(root, monkeypatch, pages=ALL_PHOTOS, feeds_=(), **kw):
    errors = []
    monkeypatch.setattr(gui.messagebox, "showerror", lambda title, text: errors.append(text))
    config.save(config.Settings(pages=dict(pages if pages is not None else config.DEFAULT_PAGES),
                                feeds=list(feeds_)))
    kw.setdefault("calendar_ok_fn", lambda: True)
    kw.setdefault("secrets", MemorySecrets({f.id: {"url": SECRET} for f in feeds_}))
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


def test_gui_tile_shows_too_large_message(root, monkeypatch, tmp_path):
    from test_image import header_only_png

    big = header_only_png(tmp_path / "big.png", 8000, 8000)  # 64 MP: over the 50 MP limit
    app, _ = make_app(root, monkeypatch)
    try:
        app.tiles[1].set_path(str(big))
        pump(root, lambda: "照片太大" in app.tiles[1].status.cget("text"))
        assert app.tiles[1].status.cget("text") == "照片太大（約 64 百萬像素）。請先縮小到 5000 萬像素以下再選。"
        assert app.tiles[1].path is None and app.tiles[1].frame is None
        assert str(app.push_btn.cget("state")) == "disabled"
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
        assert app.push_btn.cget("text") == "推送照片到裝置"
        assert "「推送照片到裝置」" in app.summary.cget("text")
    finally:
        app.worker.close()


def test_icon_files_ship_with_the_package():
    # CI installs the package before testing, so this also checks that the
    # wheel carries the package data.
    data = gui.icon_asset(gui.ICON_ICO).read_bytes()
    with Image.open(io.BytesIO(data)) as ico:
        assert ico.format == "ICO"
        assert {(16, 16), (24, 24), (32, 32), (48, 48), (256, 256)} <= set(ico.info["sizes"])
    # Tk's .ico reader takes bitmaps only: every image but the 256 px one (0 in
    # the directory) is a bitmap, not a PNG.
    for i in range(struct.unpack_from("<H", data, 4)[0]):
        side, offset = data[6 + 16 * i], struct.unpack_from("<I", data, 6 + 16 * i + 12)[0]
        assert data[offset:offset + 4] == (b"\x89PNG" if side == 0 else struct.pack("<I", 40))
    for name, side in zip(gui.ICON_PNGS, (256, 32)):
        with Image.open(io.BytesIO(gui.icon_asset(name).read_bytes())) as png:
            assert (png.format, png.mode, png.size) == ("PNG", "RGBA", (side, side))


def test_app_window_gets_the_paperhue_icon(root, monkeypatch):
    app, _ = make_app(root, monkeypatch)
    try:
        assert app.has_icon is True
    finally:
        app.worker.close()


def spy(monkeypatch, widget, method, calls):
    real = getattr(widget, method)

    def wrapper(*args, **kwargs):
        calls.append((method, args, kwargs))
        return real(*args, **kwargs)

    monkeypatch.setattr(widget, method, wrapper)


def test_windows_gets_the_ico_for_title_bar_and_taskbar(root, monkeypatch):
    if sys.platform != "win32":
        pytest.skip("Tk takes .ico files on Windows only")
    calls = []
    spy(monkeypatch, root, "iconbitmap", calls)
    spy(monkeypatch, root, "iconphoto", calls)
    assert gui.set_window_icon(root, "win32") is True
    [(method, args, kwargs)] = calls
    assert method == "iconbitmap" and not args
    assert kwargs["default"].endswith(gui.ICON_ICO)


def test_windows_title_bar_and_taskbar_get_the_image_of_their_exact_size(root):
    if sys.platform != "win32":
        pytest.skip("Windows only")
    import ctypes
    from ctypes import wintypes

    class ICONINFO(ctypes.Structure):
        _fields_ = [("fIcon", wintypes.BOOL), ("xHotspot", wintypes.DWORD), ("yHotspot", wintypes.DWORD),
                    ("hbmMask", ctypes.c_void_p), ("hbmColor", ctypes.c_void_p)]

    class BITMAP(ctypes.Structure):
        _fields_ = [("bmType", wintypes.LONG), ("bmWidth", wintypes.LONG), ("bmHeight", wintypes.LONG),
                    ("bmWidthBytes", wintypes.LONG), ("bmPlanes", wintypes.WORD), ("bmBitsPixel", wintypes.WORD),
                    ("bmBits", ctypes.c_void_p)]

    user32, gdi32 = ctypes.WinDLL("user32"), ctypes.WinDLL("gdi32")
    user32.SendMessageW.restype = ctypes.c_void_p
    user32.SendMessageW.argtypes = (ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_void_p)
    user32.GetIconInfo.argtypes = (ctypes.c_void_p, ctypes.POINTER(ICONINFO))
    gdi32.GetObjectW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p)
    gdi32.DeleteObject.argtypes = (ctypes.c_void_p,)

    def side(icon):
        info, bitmap = ICONINFO(), BITMAP()
        assert user32.GetIconInfo(icon, ctypes.byref(info))
        gdi32.GetObjectW(info.hbmColor, ctypes.sizeof(bitmap), ctypes.byref(bitmap))
        gdi32.DeleteObject(info.hbmColor)
        gdi32.DeleteObject(info.hbmMask)
        return bitmap.bmWidth

    def window_icon(kind):
        return user32.SendMessageW(int(root.wm_frame(), 16), 0x007F, kind, None)  # WM_GETICON

    with resources.as_file(gui.icon_asset(gui.ICON_ICO)) as ico:
        icons = gui.exact_windows_icons(root, str(ico))
    # ICON_SMALL (title bar) and ICON_BIG (taskbar, Alt+Tab) at SM_CXSMICON and SM_CXICON
    assert [side(icons[0]), side(icons[1])] == [user32.GetSystemMetrics(49), user32.GetSystemMetrics(11)]
    root.deiconify()  # Tk creates the window's frame, which takes the icons, when it shows the window
    pump(root, lambda: window_icon(1) == icons[1])
    assert window_icon(0) == icons[0]


def test_other_systems_get_the_png_icons(root, monkeypatch):
    calls = []
    spy(monkeypatch, root, "iconbitmap", calls)
    spy(monkeypatch, root, "iconphoto", calls)
    assert gui.set_window_icon(root, "darwin") is True
    [(method, (default, *photos), _)] = calls
    assert method == "iconphoto" and default is True
    assert [(p.width(), p.height()) for p in photos] == [(256, 256), (32, 32)]


def test_a_missing_icon_does_not_stop_the_app(root, monkeypatch):
    monkeypatch.setattr(gui, "ICON_ICO", "missing.ico")
    monkeypatch.setattr(gui, "ICON_PNGS", ("missing.png",))
    assert gui.set_window_icon(root) is False
    app, errors = make_app(root, monkeypatch)
    try:
        assert app.has_icon is False and not errors
        assert root.title() == "Paperhue"
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
        assert {str(w.cget("state")) for w in app.option_widgets} <= {"normal", "readonly"}  # grain: a dropdown
    finally:
        app.worker.close()


def test_grain_picker_replaces_the_dithering_switch(root, monkeypatch, tmp_path):
    seen = []
    real_encode = gui.image.encode

    def spy(*args, **kwargs):
        seen.append(kwargs.get("strength"))
        return real_encode(*args, **kwargs)

    monkeypatch.setattr(gui.image, "encode", spy)
    app, _ = make_app(root, monkeypatch)
    try:
        assert list(app.grain_box.cget("values")) == ["標準", "柔和", "更柔和", "最平滑"]
        assert app.grain.get() == "標準"
        assert not any(isinstance(w, gui.ttk.Checkbutton) for w in app.option_widgets)
        app.grain.set("最平滑")
        app.tiles[1].set_path(photo(tmp_path))
        pump(root, lambda: app.tiles[1].frame is not None)
        assert seen[-1] == 0.5
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


# --- calendar pages ------------------------------------------------------------

DEFAULT = None  # make_app(pages=None): use the saved/default settings


def page_image(colour):
    return Image.new("RGB", (800, 480), colour)


def test_tiles_follow_the_saved_page_kinds(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        assert {s: t.kind for s, t in app.tiles.items()} == {1: "month", 2: "agenda", 3: "todo", 4: "photo"}
        assert app.tiles[1].combo.get() == "月曆"
        assert str(app.tiles[1].pick.cget("state")) == "disabled"
        assert str(app.tiles[4].pick.cget("state")) == "normal"
    finally:
        app.worker.close()


def test_changing_a_page_kind_is_saved(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        app.set_kind(1, "photo")
        app.set_kind(4, "todo")
        assert config.load().pages == {1: "photo", 2: "agenda", 3: "todo", 4: "todo"}
        assert str(app.tiles[1].pick.cget("state")) == "normal"
        assert str(app.tiles[4].pick.cget("state")) == "disabled"
    finally:
        app.worker.close()


def test_calendar_pages_are_never_pushed_as_photos(root, monkeypatch, tmp_path):
    app, _ = make_app(root, monkeypatch)
    try:
        app.tiles[1].set_path(photo(tmp_path, "a.png"))
        app.tiles[2].set_path(photo(tmp_path, "b.png"))
        pump(root, lambda: len(app.frames()) == 2)
        app.set_kind(1, "month")
        assert set(app.frames()) == {2}
        app.set_kind(1, "photo")  # the chosen photo comes back
        pump(root, lambda: len(app.frames()) == 2)
    finally:
        app.worker.close()


def test_sync_needs_a_calendar_source(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        assert "尚未設定" in app.feeds_label.cget("text")
        assert str(app.sync_btn.cget("state")) == "disabled"
        assert str(app.feeds_btn.cget("state")) == "normal"
    finally:
        app.worker.close()


def test_sync_needs_a_calendar_page(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, feeds_=ONE_FEED)  # all photos
    try:
        assert "個人" in app.feeds_label.cget("text")
        assert str(app.sync_btn.cget("state")) == "disabled"
        app.set_kind(2, "agenda")
        assert str(app.sync_btn.cget("state")) == "normal"
    finally:
        app.worker.close()


def test_sync_now_shows_the_drawings_and_the_outcome(root, monkeypatch):
    seen = {}

    async def fake_sync(settings, progress, rendered):
        seen["pages"] = settings.calendar_pages()
        rendered({1: page_image("red"), 3: page_image("blue")})
        progress(PushEvent(1, "start", 0, 2, 0, 10))
        progress(PushEvent(1, "done", 0, 2, 10, 10))
        progress(PushEvent(3, "start", 1, 2, 0, 10))
        progress(PushEvent(3, "unchanged", 1, 2, 0, 0))
        return SyncReport(pages={1: "month", 3: "todo"}, events=4, tasks=2,
                          results={1: UploadResult.OK, 3: UploadResult.UNCHANGED})

    app, errors = make_app(root, monkeypatch, pages={1: "month", 2: "photo", 3: "todo", 4: "photo"},
                           feeds_=ONE_FEED, sync_fn=fake_sync)
    try:
        app.sync_now()
        pump(root, lambda: "同步完成" in app.summary.cget("text"))
        assert seen["pages"] == {1: "month", 3: "todo"}
        assert app.tiles[1].photo is not None and app.tiles[3].photo is not None
        assert app.tiles[1].status.cget("text") == "完成"
        assert "第 1 頁 月曆：已更新" in app.summary.cget("text")
        assert app.device.cget("text") == "裝置狀態：剛完成同步（按「讀取狀態」可更新）"
        assert syncjob.last()["ok"] is True
        assert "上次同步" in app.last_sync.cget("text")
        assert not errors
    finally:
        app.worker.close()


@pytest.mark.parametrize("error, phrase", [
    (NoFeeds("尚未設定行事曆來源"), "行事曆來源…"),
    (FeedError("個人：HTTP 404（找不到：網址可能已重設或刪除）"), "無法讀取行事曆來源"),
])
def test_sync_errors_are_explained_and_logged(root, monkeypatch, error, phrase):
    async def failing_sync(settings, progress, rendered):
        raise error

    app, errors = make_app(root, monkeypatch, pages=DEFAULT, feeds_=ONE_FEED, sync_fn=failing_sync)
    try:
        app.sync_now()
        pump(root, lambda: errors)
        assert phrase in errors[0]
        assert syncjob.last()["ok"] is False
        assert str(app.sync_btn.cget("state")) == "normal"
    finally:
        app.worker.close()


def parsed(events=3, tasks=2):
    return ical.ParsedFeed(name="x", events=[None] * events, tasks=[Task(f"t{i}") for i in range(tasks)])


def test_add_a_source_in_the_dialog(root, monkeypatch):
    checked = []

    def probe(url, user="", password=""):
        checked.append((url, user, password))
        return parsed()

    app, errors = make_app(root, monkeypatch, pages=DEFAULT, probe_fn=probe)
    try:
        dialog = app.open_feeds()
        form = dialog.add()
        form.name.set("個人")
        form.url.set("  webcal://calendar.google.com/calendar/ical/x/private-abc/basic.ics ")
        form.colour.set("藍")
        form.save()
        pump(root, lambda: not form.win.winfo_exists())
        assert checked == [("https://calendar.google.com/calendar/ical/x/private-abc/basic.ics", "", "")]
        (feed,) = config.load().feeds
        assert (feed.name, feed.color) == ("個人", "blue")
        assert app.secrets.get(feed.id)["url"].endswith("private-abc/basic.ics")
        assert dialog.tree.item(feed.id)["values"][2] == "calendar.google.com"  # host only, never the path
        assert "個人" in app.feeds_label.cget("text") and str(app.sync_btn.cget("state")) == "normal"
        assert "3 個行程、2 項待辦" in app.summary.cget("text")
        assert not errors
    finally:
        app.worker.close()


def test_a_bad_address_is_not_saved(root, monkeypatch):
    def probe(url, user="", password=""):
        raise FeedError("HTTP 404（找不到：網址可能已重設或刪除）")

    app, _ = make_app(root, monkeypatch, pages=DEFAULT, probe_fn=probe)
    try:
        form = app.open_feeds().add()
        form.name.set("壞的")
        form.url.set(SECRET)
        form.save()
        pump(root, lambda: "無法使用" in form.status.cget("text"))
        assert config.load().feeds == [] and app.secrets.values == {}
        assert form.win.winfo_exists()  # stays open to correct the address
    finally:
        app.worker.close()


def test_rename_without_a_new_address_does_not_download(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=DEFAULT, feeds_=ONE_FEED,
                      probe_fn=lambda *a, **kw: pytest.fail("no download for a rename"))
    try:
        dialog = app.open_feeds()
        dialog.tree.selection_set("p1")
        form = dialog.edit()
        form.name.set("我的")
        form.colour.set("綠")
        form.save()
        assert [(f.name, f.color) for f in config.load().feeds] == [("我的", "green")]
        assert app.secrets.get("p1") == {"url": SECRET}  # untouched
    finally:
        app.worker.close()


def test_remove_a_source(root, monkeypatch):
    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: True)
    app, _ = make_app(root, monkeypatch, pages=DEFAULT, feeds_=ONE_FEED)
    try:
        dialog = app.open_feeds()
        dialog.tree.selection_set("p1")
        dialog.remove()
        assert config.load().feeds == [] and app.secrets.get("p1") is None
        assert "尚未設定" in app.feeds_label.cget("text")
    finally:
        app.worker.close()


def test_without_the_calendar_packages_the_app_still_works(root, monkeypatch, tmp_path):
    app, _ = make_app(root, monkeypatch, calendar_ok_fn=lambda: False)
    try:
        assert "ulani-epaper[calendar]" in app.feeds_label.cget("text")
        assert str(app.feeds_btn.cget("state")) == "disabled" and app.open_feeds() is None
        app.tiles[1].set_path(photo(tmp_path))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
    finally:
        app.worker.close()


def test_changes_made_elsewhere_are_not_overwritten(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        # the CLI adds a source and changes the times while the app is open
        config.save(config.Settings(feeds=list(ONE_FEED), times=["07:00"]))
        app.set_kind(4, "todo")
        saved = config.load()
        assert saved.feeds == list(ONE_FEED) and saved.times == ["07:00"] and saved.pages[4] == "todo"
    finally:
        app.worker.close()


def test_set_kind_is_refused_while_busy(root, monkeypatch, tmp_path):
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
        app.set_kind(2, "month")
        assert app.tiles[2].kind == "photo" and config.load().pages[2] == "photo"
        release.set()
        pump(root, lambda: "完成" in app.summary.cget("text"))
    finally:
        app.worker.close()


@pytest.mark.parametrize("answer, kinds", [(True, ["photo", "photo", "photo", "photo"]),
                                            (False, ["month", "agenda", "todo", "photo"])])
def test_dropping_four_photos_onto_the_app(root, monkeypatch, tmp_path, answer, kinds):
    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: answer)
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        app.load_dropped([photo(tmp_path, f"{i}.png") for i in range(4)])
        assert [app.tiles[s].kind for s in (1, 2, 3, 4)] == kinds
        assert [bool(app.tiles[s].path) for s in (1, 2, 3, 4)] == [k == "photo" for k in kinds]
        if not answer:
            assert "只載入了 1 張照片" in app.summary.cget("text")
    finally:
        app.worker.close()


def test_closing_during_a_sync_asks_first(root, monkeypatch):
    release = threading.Event()
    asked = []

    async def slow_sync(settings, progress, rendered):
        while not release.is_set():
            await asyncio.sleep(0.01)
        return SyncReport()

    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: asked.append(a) or False)
    app, _ = make_app(root, monkeypatch, pages=DEFAULT, feeds_=ONE_FEED, sync_fn=slow_sync)
    try:
        app.sync_now()
        root.update()
        app.close()  # answered "no": stays open
        assert asked and root.winfo_exists()
    finally:
        release.set()
        app.worker.close()


def test_a_damaged_sync_log_does_not_stop_the_app(root, monkeypatch):
    syncjob.log_path().parent.mkdir(parents=True, exist_ok=True)
    syncjob.log_path().write_bytes(b'{"time": "2026-10-12T06:00:00+08:00", "ok": true, "mess\xe9\x00\x00')
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        assert "尚無紀錄" in app.last_sync.cget("text")
    finally:
        app.worker.close()


def test_one_bad_message_does_not_stop_the_poll_loop(root, monkeypatch, capsys):
    app, _ = make_app(root, monkeypatch)
    try:
        app.inbox.put(("info", "done", {"battery": None}))  # broken: no "shown", battery None
        app.inbox.put(("info", "done", {"battery": Battery(level=3, charging=False), "shown": 2}))
        pump(root, lambda: "第 2 頁" in app.device.cget("text"))
    finally:
        app.worker.close()


def test_schedule_is_applied_and_saved(root, monkeypatch):
    installed, removed = [], []
    app, errors = make_app(root, monkeypatch, pages=DEFAULT,
                           schedule_install_fn=installed.append, schedule_remove_fn=lambda: removed.append(1) or True)
    try:
        assert app.apply_schedule("18:00，7:30, 12:00") is True
        assert installed == [["07:30", "12:00", "18:00"]] and config.load().times == ["07:30", "12:00", "18:00"]
        assert app.apply_schedule("7pm") is False and errors
        app.remove_schedule()
        assert removed == [1]
    finally:
        app.worker.close()


# --- message board -----------------------------------------------------------

from ulani_epaper import layouts, sync  # noqa: E402
from ulani_epaper import notes as note_store  # noqa: E402
from ulani_epaper.agenda import LOCAL  # noqa: E402

BOARD_PAGES = {1: "month", 2: "photo", 3: "board", 4: "message"}
NOT_FOUND = "could not connect after 4 attempts: no e-paper device found"


def fake_post(calls, fail=None):
    """post_fn that records what it was asked and reports like sync.post."""
    async def post(settings, show, progress, rendered):
        pages = settings.board_pages()
        calls.append({"show": show, "pages": pages, "notes": note_store.load()})
        if fail:
            raise fail
        rendered({slot: page_image("white") for slot in pages})
        target = sync.show_target(pages, show)
        for i, slot in enumerate(pages):
            progress(PushEvent(slot, "start", i, len(pages)))
            progress(PushEvent(slot, "done", i, len(pages)))
        if target:
            progress(PushEvent(target, "switching", len(pages), len(pages)))
        return SyncReport(pages=dict(pages), notes=len(note_store.load()), show=target,
                          results={slot: UploadResult.OK for slot in pages})
    return post


def no_post(settings, show, progress, rendered):
    pytest.fail("nothing may be pushed")


def widget_texts(widget):
    found = []
    for w in widget.winfo_children():
        try:
            found.append(str(w.cget("text")))
        except tk.TclError:
            pass
        found += widget_texts(w)
    return found


def test_board_tiles_show_the_saved_notes_at_once(root, monkeypatch):
    note_store.add("晚餐在冰箱", "orange")
    app, errors = make_app(root, monkeypatch, pages=BOARD_PAGES, post_fn=no_post,
                           sync_fn=lambda *a: pytest.fail("no sync for a preview"))
    try:
        assert {"留言板", "大字留言"} <= set(app.tiles[1].combo.cget("values"))
        for slot, kind in ((3, "board"), (4, "message")):
            tile = app.tiles[slot]
            assert tile.photo is not None and tile.canvas.cget("text") == ""
            assert "「留言…」" in tile.name.cget("text")
            expected = layouts.BOARD_RENDERERS[kind](note_store.load(), LOCAL)
            assert app.board_drawing(kind).tobytes() == expected.tobytes()
        app.set_kind(2, "board")  # chosen in the 顯示 selector: drawn at once, nothing to sync
        assert app.tiles[2].photo is not None and app.tiles[2].canvas.cget("text") == ""
        assert config.load().pages[2] == "board"
        app.tiles[2].clicked()  # a click on a board tile opens the dialog
        assert app.notes_dialog and app.notes_dialog.win.winfo_exists()
        assert not errors
    finally:
        app.worker.close()


def test_notes_button_sits_beside_the_calendar_sources_button(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=DEFAULT, calendar_ok_fn=lambda: False)
    try:
        assert app.notes_btn.cget("text") == "留言…"
        row = app.feeds_btn.master.pack_slaves()
        assert row.index(app.notes_btn) == row.index(app.feeds_btn) + 1
        assert str(app.notes_btn.cget("state")) == "normal"  # needs no calendar packages
    finally:
        app.worker.close()


def test_post_a_note_from_the_dialog(root, monkeypatch):
    calls = []
    app, errors = make_app(root, monkeypatch, pages=BOARD_PAGES, post_fn=fake_post(calls))
    try:
        app.notes_btn.invoke()
        dialog = app.notes_dialog
        assert dialog.win.title() == "留言" and dialog.counter.cget("text") == "0 / 300"
        assert [b.cget("text") for b in dialog.colour_buttons] == ["黃", "橘", "綠", "藍", "紅"]
        assert dialog.colour.get() == "yellow" and dialog.help.cget("text") == ""
        assert dialog.post_btn.cget("text") == "張貼並顯示"
        dialog.text.insert("1.0", "晚餐在冰箱\n六點回來")
        pump(root, lambda: dialog.counter.cget("text") == "10 / 300")
        dialog.colour.set("green")
        dialog.post()
        (note,) = note_store.load()  # saved at once, before the push
        assert (note.text, note.color) == ("晚餐在冰箱\n六點回來", "green")
        assert dialog.written() == "" and dialog.counter.cget("text") == "0 / 300"
        assert dialog.tree.get_children() == (note.id,)
        assert dialog.tree.item(note.id)["values"] == [note_store.when(note), "晚餐在冰箱 …"]
        pump(root, lambda: "留言已送到裝置" in app.summary.cget("text"))
        assert calls == [{"show": "auto", "pages": {3: "board", 4: "message"}, "notes": [note]}]
        assert "第 3 頁 留言板：已更新" in app.summary.cget("text")
        assert "裝置顯示第 4 頁" in app.summary.cget("text")
        assert dialog.status.cget("text") == app.summary.cget("text")
        assert app.tiles[3].status.cget("text") == "完成"
        assert app.tiles[4].status.cget("text").startswith("切換顯示這一頁")
        assert app.board_drawing("message").tobytes() == layouts.render_message([note], LOCAL).tobytes()
        assert app.device.cget("text").startswith("裝置狀態：剛完成推送留言")
        assert str(dialog.post_btn.cget("state")) == "normal"
        assert not errors
    finally:
        app.worker.close()


def test_empty_or_too_long_notes_are_explained_not_posted(root, monkeypatch):
    calls = []
    app, _ = make_app(root, monkeypatch, pages=BOARD_PAGES, post_fn=fake_post(calls))
    try:
        dialog = app.open_notes()
        dialog.post()
        assert "留言是空的" in dialog.status.cget("text")
        dialog.text.insert("1.0", "字" * 301)
        pump(root, lambda: dialog.counter.cget("text") == "301 / 300")
        assert str(dialog.counter.cget("foreground")) == "#c00"
        dialog.post()
        assert "最多 300 字" in dialog.status.cget("text")
        assert note_store.load() == [] and calls == []
        assert dialog.written() == "字" * 301  # kept, to be shortened
    finally:
        app.worker.close()


def test_delete_and_clear_push_without_switching(root, monkeypatch):
    calls, asked = [], []
    first, second, third = (note_store.add(text) for text in ("一", "二", "三"))
    app, errors = make_app(root, monkeypatch, pages=BOARD_PAGES, post_fn=fake_post(calls))
    try:
        dialog = app.open_notes()
        assert dialog.tree.get_children() == (third.id, second.id, first.id)  # newest first
        dialog.remove()  # nothing selected
        assert "請先" in dialog.status.cget("text") and calls == []
        dialog.tree.selection_set(second.id)
        dialog.remove()
        assert note_store.load() == [third, first] and dialog.tree.get_children() == (third.id, first.id)
        pump(root, lambda: len(calls) == 1 and app.job is None)
        monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: asked.append(a) or False)
        dialog.clear()
        assert asked and "2 則" in asked[0][1] and note_store.load() == [third, first]  # answered no
        monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: True)
        dialog.clear()
        assert note_store.load() == [] and dialog.tree.get_children() == ()
        pump(root, lambda: len(calls) == 2 and app.job is None)
        assert [c["show"] for c in calls] == ["none", "none"]
        assert "留言已送到裝置" in app.summary.cget("text") and "裝置顯示" not in app.summary.cget("text")
        assert {str(b.cget("state")) for b in (dialog.remove_btn, dialog.clear_btn)} == {"disabled"}  # none left
        assert not errors
    finally:
        app.worker.close()


def test_posting_needs_a_board_page(root, monkeypatch):
    calls = []
    old = note_store.add("舊的")
    app, _ = make_app(root, monkeypatch, post_fn=fake_post(calls))  # every page a photo
    try:
        dialog = app.open_notes()
        assert str(dialog.post_btn.cget("state")) == "disabled"
        assert "「留言板」或「大字留言」" in dialog.help.cget("text")
        dialog.text.insert("1.0", "hi")
        dialog.post()
        assert note_store.load() == [old] and calls == []
        dialog.tree.selection_set(old.id)
        dialog.remove()  # saved; nothing on the device shows notes, so nothing is pushed
        assert note_store.load() == [] and calls == [] and app.job is None
        app.set_kind(2, "message")  # chosen in the main window while the dialog is open
        assert str(dialog.post_btn.cget("state")) == "normal" and dialog.help.cget("text") == ""
        dialog.post()
        pump(root, lambda: calls and app.job is None)
        assert calls[0]["pages"] == {2: "message"} and calls[0]["show"] == "auto"
    finally:
        app.worker.close()


def test_a_failed_post_keeps_the_note_and_explains(root, monkeypatch):
    calls = []
    app, errors = make_app(root, monkeypatch, pages=BOARD_PAGES, post_fn=fake_post(calls, UlaniError(NOT_FOUND)))
    try:
        dialog = app.open_notes()
        dialog.text.insert("1.0", "hi")
        dialog.post()
        pump(root, lambda: errors)
        assert "找不到裝置" in errors[0]
        assert [n.text for n in note_store.load()] == ["hi"]
        assert "沒有送到裝置" in dialog.status.cget("text") and str(dialog.status.cget("foreground")) == "#c00"
        assert app.tiles[3].status.cget("text") == "未完成"
        assert str(dialog.post_btn.cget("state")) == "normal"  # can post again
    finally:
        app.worker.close()


def test_the_dialog_is_locked_while_posting(root, monkeypatch):
    release = threading.Event()
    asked = []

    async def slow_post(settings, show, progress, rendered):
        while not release.is_set():
            await asyncio.sleep(0.01)
        return SyncReport(pages=settings.board_pages(), results={})

    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: asked.append(a) or False)
    note_store.add("舊的")
    app, _ = make_app(root, monkeypatch, pages=BOARD_PAGES, post_fn=slow_post)
    try:
        dialog = app.open_notes()
        dialog.text.insert("1.0", "新的")
        dialog.post()
        root.update()
        assert app.job == "post"
        assert {str(b.cget("state")) for b in (dialog.post_btn, dialog.remove_btn, dialog.clear_btn,
                                                app.notes_btn)} == {"disabled"}
        app.close()  # still sending: asks first; "no" keeps the window
        assert asked and root.winfo_exists()
        release.set()
        pump(root, lambda: app.job is None)
        assert str(dialog.post_btn.cget("state")) == "normal"
    finally:
        release.set()
        app.worker.close()


def test_a_damaged_notes_file_is_shown_not_overwritten(root, monkeypatch):
    note_store.notes_path().parent.mkdir(parents=True, exist_ok=True)
    note_store.notes_path().write_text("{broken", encoding="utf-8")
    calls = []
    app, _ = make_app(root, monkeypatch, pages=BOARD_PAGES, post_fn=fake_post(calls))
    try:
        assert "留言檔無法讀取" in app.tiles[3].canvas.cget("text")
        dialog = app.open_notes()
        assert "notes file" in dialog.status.cget("text")
        dialog.text.insert("1.0", "hi")
        dialog.post()
        assert "無法儲存留言" in dialog.status.cget("text") and calls == []
        assert note_store.notes_path().read_text(encoding="utf-8") == "{broken"
    finally:
        app.worker.close()


def test_sync_works_for_board_pages_without_calendar_sources(root, monkeypatch):
    seen = []

    async def fake_sync(settings, progress, rendered):
        seen.append(settings.calendar_pages())
        return SyncReport(pages={4: "board"}, results={4: UploadResult.UNCHANGED})

    app, errors = make_app(root, monkeypatch, pages={1: "photo", 2: "photo", 3: "photo", 4: "board"},
                           sync_fn=fake_sync, calendar_ok_fn=lambda: False)
    try:
        assert str(app.sync_btn.cget("state")) == "normal"
        app.sync_now()
        pump(root, lambda: "同步完成" in app.summary.cget("text"))
        assert seen == [{4: "board"}] and not errors
    finally:
        app.worker.close()


def test_message_board_texts_call_the_hardware_a_device(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, post_fn=fake_post([]))
    try:
        dialog = app.open_notes()
        shown = "".join(widget_texts(dialog.win)) + app.notes_btn.cget("text")
        assert "留言" in shown and "裝置" in shown and "月曆" not in shown
        report = SyncReport(pages={3: "board"}, notes=1, show=3, results={3: UploadResult.OK})
        assert "月曆" not in gui.post_summary(report) and "月曆" not in gui.NO_BOARD_HELP
    finally:
        app.worker.close()
