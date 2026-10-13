import asyncio
import gc
import io
import os
import struct
import sys
import threading
import time
from importlib import resources

import pytest
from PIL import Image

tk = pytest.importorskip("tkinter")

from ulani_epaper import config, feeds, gui, ical, strings, syncjob  # noqa: E402
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


def fake_push(calls, fail=None):
    """push_fn that records what it was asked and answers like sync.push_all: it sends every page in scope
    that has something to send (a photo page with a photo, a card page with a chosen card), each changed."""
    async def push(settings, photos, only, progress, rendered):
        calls.append({"pages": dict(settings.pages), "photos": dict(photos), "only": only,
                      "card_choice": dict(settings.card_choice)})
        if fail:
            raise fail
        pages = {slot: kind for slot, kind in sorted(settings.pages.items()) if only in (None, slot)
                 and (kind != "photo" or slot in photos) and (kind != "card" or slot in settings.card_choice)}
        rendered({slot: Image.new("RGB", (800, 480), "white") for slot, kind in pages.items() if kind != "photo"})
        for i, slot in enumerate(pages):
            progress(PushEvent(slot, "start", i, len(pages), 0, 10))
            progress(PushEvent(slot, "done", i, len(pages), 10, 10))
        settings.card_pages = {slot: "pushed" for slot, kind in pages.items() if kind == "card"}
        return SyncReport(pages=pages, results={slot: UploadResult.OK for slot in pages})
    return push


def no_push(settings, photos, only, progress, rendered):
    pytest.fail("nothing may be pushed")


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

    async def fake_push(settings, photos, only, progress, rendered):
        seen["frames"], seen["only"] = photos, only
        for i, slot in enumerate(sorted(photos)):
            progress(PushEvent(slot, "start", i, len(photos), 0, 10))
            progress(PushEvent(slot, "sending", i, len(photos), 5, 10))
            progress(PushEvent(slot, "done", i, len(photos), 10, 10))
        return SyncReport(pages={s: "photo" for s in photos}, results={s: UploadResult.OK for s in photos})

    app, errors = make_app(root, monkeypatch, push_fn=fake_push)
    try:
        app.tiles[1].set_path(photo(tmp_path, "a.png", "red"))
        app.tiles[4].set_path(photo(tmp_path, "b.png", "blue"))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.push()
        pump(root, lambda: "完成" in app.summary.cget("text"))
        assert set(seen["frames"]) == {1, 4} and seen["only"] is None
        assert app.tiles[1].status.cget("text") == "完成" and app.tiles[1].bar.cget("value") == 100
        assert app.tiles[2].status.cget("text") == ""
        assert app.summary.cget("text") == "完成：2 頁已更新，0 頁原本就相同。"
        assert not errors
    finally:
        app.worker.close()


def test_push_failure_shows_a_friendly_error(root, monkeypatch, tmp_path):
    async def failing_push(settings, photos, only, progress, rendered):
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


def test_show_on_device_switches_the_page_or_says_it_is_shown(root, monkeypatch):
    asked = []

    async def fake_show(slot):
        asked.append(slot)
        return slot != 2  # page 2 is on screen already

    app, _ = make_app(root, monkeypatch, show_fn=fake_show)
    try:
        assert app.tiles[3].show_btn.cget("text") == "在裝置上顯示"
        app.tiles[3].show_btn.invoke()
        assert app.summary.cget("text") == "正在切換到第 3 頁…"
        pump(root, lambda: app.job is None)
        assert app.summary.cget("text") == "已切換到第 3 頁，裝置畫面重畫約需 40 秒。"
        assert str(app.tiles[1].show_btn.cget("state")) == "normal"
        app.tiles[2].show_btn.invoke()
        pump(root, lambda: app.job is None)
        assert app.summary.cget("text") == "裝置已經在顯示第 2 頁。"
        assert asked == [3, 2]
    finally:
        app.worker.close()


def test_show_on_device_reports_a_failure(root, monkeypatch):
    async def failing_show(slot):
        raise UlaniError("no e-paper device found (is Bluetooth on and the device nearby?)")

    app, errors = make_app(root, monkeypatch, show_fn=failing_show)
    try:
        app.tiles[1].show_btn.invoke()
        pump(root, lambda: app.job is None)
        assert app.summary.cget("text") == "切換頁面失敗，請看錯誤訊息後再試一次。"
        assert len(errors) == 1 and errors[0].startswith("找不到裝置或連不上")
    finally:
        app.worker.close()


MIXED = {1: "month", 2: "photo", 3: "board", 4: "card"}


def test_push_to_device_sends_every_page_that_has_something_to_send(root, monkeypatch, tmp_path):
    calls = []
    card = cards.add(cards.Card(background=cards.Background("red")))
    app, errors = make_app(root, monkeypatch, pages=MIXED, push_fn=fake_push(calls))
    try:
        assert app.push_btn.cget("text") == "推送到裝置"
        assert str(app.push_btn.cget("state")) == "normal"  # the calendar and notes pages need nothing chosen
        app.tiles[2].set_path(photo(tmp_path))
        assert str(app.push_btn.cget("state")) == "disabled"  # until the preview is ready
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.reload_settings().card_choice = {4: card.id}  # as My cards saves it
        app.save_settings()
        app.push_btn.invoke()
        assert app.summary.cget("text") == "讀取行事曆與待辦事項…" and app.tiles[1].status.cget("text") == "讀取行事曆中…"
        pump(root, lambda: app.job is None)
        (call,) = calls
        assert call["only"] is None and call["pages"] == MIXED and call["card_choice"] == {4: card.id}
        assert call["photos"] == {2: app.tiles[2].frame}
        assert app.summary.cget("text") == "完成：4 頁已更新，0 頁原本就相同。"
        assert {app.tiles[s].status.cget("text") for s in MIXED} == {"完成"}
        assert app.calendar_images[1][0] == "month"  # the calendar page shows what was sent
        assert config.load().card_pages == {4: "pushed"} and config.load().card_choice == {4: card.id}
        assert app.device.cget("text") == "裝置狀態：剛完成推送（按「讀取狀態」可更新）"
        assert not errors
    finally:
        app.worker.close()


def test_update_this_page_sends_only_that_page(root, monkeypatch, tmp_path):
    calls = []
    app, errors = make_app(root, monkeypatch, pages=MIXED, push_fn=fake_push(calls))
    try:
        tiles = app.tiles
        assert tiles[3].update_btn.cget("text") == "更新這頁"
        assert {s: str(tiles[s].update_btn.cget("state")) for s in MIXED} == {
            1: "normal", 2: "disabled", 3: "normal", 4: "disabled"}  # no photo, no card chosen yet
        tiles[2].set_path(photo(tmp_path))
        pump(root, lambda: str(tiles[2].update_btn.cget("state")) == "normal")
        tiles[3].update_btn.invoke()
        pump(root, lambda: app.job is None)
        assert [c["only"] for c in calls] == [3]
        assert tiles[3].status.cget("text") == "完成" and tiles[2].status.cget("text") == "預覽為裝置實際顯示的 7 色效果"
        assert app.summary.cget("text") == "完成：1 頁已更新，0 頁原本就相同。"
        tiles[2].update_btn.invoke()
        pump(root, lambda: app.job is None)
        assert calls[-1]["only"] == 2 and calls[-1]["photos"][2] == tiles[2].frame
        assert not errors
    finally:
        app.worker.close()


def test_a_calendar_page_that_cannot_be_read_is_an_error_for_that_page_alone(root, monkeypatch):
    calls = []
    error = FeedError("個人：HTTP 404（找不到：網址可能已重設或刪除）")
    app, errors = make_app(root, monkeypatch, pages=MIXED, feeds_=ONE_FEED, push_fn=fake_push(calls, error))
    try:
        app.tiles[1].update_btn.invoke()
        pump(root, lambda: errors)
        assert "無法讀取行事曆來源" in errors[0] and calls[0]["only"] == 1
        assert app.tiles[1].status.cget("text") == "未完成"
    finally:
        app.worker.close()


def test_a_push_without_the_calendars_says_what_was_left_out(root, monkeypatch, tmp_path):
    left_out = strings.t("push_no_calendars", error="個人：無法連線到 calendar.google.com（gaierror）")

    async def push(settings, photos, only, progress, rendered):
        progress(PushEvent(3, "start", 0, 1, 0, 10))
        progress(PushEvent(3, "unchanged", 0, 1, 0, 0))
        return SyncReport(pages={3: "board"}, results={3: UploadResult.UNCHANGED}, warnings=[left_out])

    app, errors = make_app(root, monkeypatch, pages=MIXED, push_fn=push)
    try:
        app.push()
        pump(root, lambda: app.job is None)
        assert app.summary.cget("text") == ("完成：0 頁已更新，1 頁原本就相同。注意：無法讀取行事曆，行事曆頁這次沒有更新："
                                            "個人：無法連線到 calendar.google.com（gaierror）")
        assert app.tiles[3].status.cget("text") == "內容沒有變化，略過"
        assert app.tiles[1].status.cget("text") == "未完成"  # the calendar page was not sent
        assert not errors
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
        pump(root, lambda: "照片超過" in app.tiles[1].status.cget("text"))
        assert app.tiles[1].status.cget("text") == "照片超過 5000 萬像素的上限，請先縮小再選。"
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
        assert app.push_btn.cget("text") == "推送到裝置"
        assert "「推送到裝置」" in app.summary.cget("text") and "「更新這頁」" in app.summary.cget("text")
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


def slow_push(release):
    async def push(settings, photos, only, progress, rendered):
        while not release.is_set():
            await asyncio.sleep(0.01)
        return SyncReport(pages={s: "photo" for s in photos}, results={s: UploadResult.OK for s in photos})
    return push


def test_options_are_locked_during_a_push(root, monkeypatch, tmp_path):
    release = threading.Event()
    app, _ = make_app(root, monkeypatch, push_fn=slow_push(release))
    try:
        app.tiles[1].set_path(photo(tmp_path))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.push()
        root.update()
        assert {str(w.cget("state")) for w in app.option_widgets} == {"disabled"}
        assert {str(t.update_btn.cget("state")) for t in app.tiles.values()} == {"disabled"}
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

    async def push_then_fail(settings, photos, only, progress, rendered):
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
    app, _ = make_app(root, monkeypatch, push_fn=fake_push([]))
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
        assert app.tiles[1].combo.get() == "本日＋月曆"
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


def test_sync_needs_no_calendar_source(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)  # no feeds: the public Taiwan holidays are shown
    try:
        assert "尚未設定" in app.feeds_label.cget("text")
        assert str(app.sync_btn.cget("state")) == "normal"
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
        assert "第 1 頁 本日＋月曆：已更新" in app.summary.cget("text")
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
    app, _ = make_app(root, monkeypatch, push_fn=slow_push(release))
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
        assert app.apply_schedule("") is False and len(errors) == 2 and len(installed) == 1  # a time is needed
        app.remove_schedule()
        assert removed == [1]
    finally:
        app.worker.close()


def test_a_settings_file_that_will_not_load_is_never_overwritten(root, monkeypatch):
    # e.g. a page kind written by a newer release: the feed list must survive every button
    bad = ('{"pages": {"1": "hologram"}, "feeds": [{"id": "p1", "name": "個人"}], "times": ["07:30"]}')
    config.settings_path().parent.mkdir(parents=True, exist_ok=True)
    config.settings_path().write_text(bad, encoding="utf-8")
    errors, installed = [], []
    monkeypatch.setattr(gui.messagebox, "showerror", lambda title, text: errors.append(text))
    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: True)
    app = gui.App(root, calendar_ok_fn=lambda: True, secrets=MemorySecrets(), schedule_install_fn=installed.append)
    try:
        assert len(errors) == 1  # the start-up message
        app.set_language("en")
        app.set_kind(1, "photo")
        assert app.apply_schedule("18:00") is False and installed == []
        assert len(errors) == 4
        assert config.settings_path().read_text(encoding="utf-8") == bad
        config.settings_path().write_text(bad.replace("hologram", "month"), encoding="utf-8")  # fixed by hand
        app.set_kind(1, "photo")
        assert config.load().pages[1] == "photo" and [f.id for f in config.load().feeds] == ["p1"]
    finally:
        app.worker.close()


# --- message board -----------------------------------------------------------

from ulani_epaper import layouts  # noqa: E402
from ulani_epaper import notes as note_store  # noqa: E402
from ulani_epaper.agenda import LOCAL  # noqa: E402

BOARD_PAGES = {1: "month", 2: "photo", 3: "board", 4: "message"}


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
    app, errors = make_app(root, monkeypatch, pages=BOARD_PAGES, push_fn=no_push,
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


def test_adding_a_note_only_saves_it_and_redraws_the_notes_pages(root, monkeypatch):
    app, errors = make_app(root, monkeypatch, pages=BOARD_PAGES, push_fn=no_push)
    try:
        app.notes_btn.invoke()
        dialog = app.notes_dialog
        assert dialog.win.title() == "留言" and dialog.counter.cget("text") == "0 / 300"
        assert [b.cget("text") for b in dialog.colour_buttons] == ["黃", "橘", "綠", "藍", "紅"]
        assert dialog.colour.get() == "yellow" and dialog.help.cget("text") == ""
        assert dialog.post_btn.cget("text") == "新增留言" and not hasattr(dialog, "resend_btn")
        assert dialog.hint.cget("text") == "留言會在你按主視窗的「推送到裝置」或留言頁的「更新這頁」時送到裝置。"
        dialog.text.insert("1.0", "晚餐在冰箱\n六點回來")
        pump(root, lambda: dialog.counter.cget("text") == "10 / 300")
        dialog.colour.set("green")
        dialog.post()
        (note,) = note_store.load()
        assert (note.text, note.color) == ("晚餐在冰箱\n六點回來", "green")
        assert dialog.written() == "" and dialog.counter.cget("text") == "0 / 300"
        assert dialog.tree.get_children() == (note.id,)
        assert dialog.tree.item(note.id)["values"] == [note_store.when(note), "晚餐在冰箱 …"]
        assert dialog.status.cget("text") == "已新增留言。"
        root.update()
        assert app.job is None and not app.worker.busy  # nothing goes to the device
        assert app.tiles[4].canvas.cget("text") == "" and app.tiles[3].status.cget("text") == ""
        assert app.board_drawing("message").tobytes() == layouts.render_message([note], LOCAL).tobytes()
        assert str(dialog.post_btn.cget("state")) == "normal"
        assert not errors
    finally:
        app.worker.close()


def test_empty_or_too_long_notes_are_explained_not_saved(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=BOARD_PAGES, push_fn=no_push)
    try:
        dialog = app.open_notes()
        dialog.post()
        assert "留言是空的" in dialog.status.cget("text")
        dialog.text.insert("1.0", "字" * 301)
        pump(root, lambda: dialog.counter.cget("text") == "301 / 300")
        assert str(dialog.counter.cget("foreground")) == "#c00"
        dialog.post()
        assert "最多 300 字" in dialog.status.cget("text")
        assert note_store.load() == []
        assert dialog.written() == "字" * 301  # kept, to be shortened
    finally:
        app.worker.close()


def test_delete_and_clear_only_save(root, monkeypatch):
    asked = []
    first, second, third = (note_store.add(text) for text in ("一", "二", "三"))
    app, errors = make_app(root, monkeypatch, pages=BOARD_PAGES, push_fn=no_push)
    try:
        dialog = app.open_notes()
        assert dialog.tree.get_children() == (third.id, second.id, first.id)  # newest first
        dialog.remove()  # nothing selected
        assert "請先" in dialog.status.cget("text")
        dialog.tree.selection_set(second.id)
        dialog.remove()
        assert note_store.load() == [third, first] and dialog.tree.get_children() == (third.id, first.id)
        assert app.board_drawing("board").tobytes() == layouts.render_board([third, first], LOCAL).tobytes()
        monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: asked.append(a) or False)
        dialog.clear()
        assert asked and "2 則" in asked[0][1] and note_store.load() == [third, first]  # answered no
        monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: True)
        dialog.clear()
        assert note_store.load() == [] and dialog.tree.get_children() == ()
        root.update()
        assert app.job is None and not app.worker.busy  # nothing goes to the device
        assert {str(b.cget("state")) for b in (dialog.remove_btn, dialog.clear_btn)} == {"disabled"}  # none left
        assert not errors
    finally:
        app.worker.close()


def test_adding_a_note_needs_a_board_page(root, monkeypatch):
    old = note_store.add("舊的")
    app, _ = make_app(root, monkeypatch, push_fn=no_push)  # every page a photo
    try:
        dialog = app.open_notes()
        assert str(dialog.post_btn.cget("state")) == "disabled"
        assert "「留言板」或「大字留言」" in dialog.help.cget("text")
        dialog.text.insert("1.0", "hi")
        dialog.post()
        assert note_store.load() == [old]
        dialog.tree.selection_set(old.id)
        dialog.remove()
        assert note_store.load() == [] and app.job is None
        app.set_kind(2, "message")  # chosen in the main window while the dialog is open
        assert str(dialog.post_btn.cget("state")) == "normal" and dialog.help.cget("text") == ""
        dialog.post()
        assert [n.text for n in note_store.load()] == ["hi"] and app.job is None
    finally:
        app.worker.close()


def test_update_this_page_on_a_notes_page_sends_the_saved_notes(root, monkeypatch):
    calls = []
    note_store.add("hi")
    app, errors = make_app(root, monkeypatch, pages=BOARD_PAGES, push_fn=fake_push(calls))
    try:
        app.tiles[4].update_btn.invoke()
        pump(root, lambda: app.job is None)
        assert [c["only"] for c in calls] == [4] and app.tiles[4].status.cget("text") == "完成"
        assert app.summary.cget("text") == "完成：1 頁已更新，0 頁原本就相同。"
        assert not errors
    finally:
        app.worker.close()


def test_the_dialog_is_locked_while_pushing(root, monkeypatch):
    release = threading.Event()
    asked = []
    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: asked.append(a) or False)
    note_store.add("舊的")
    app, _ = make_app(root, monkeypatch, pages=BOARD_PAGES, push_fn=slow_push(release))
    try:
        dialog = app.open_notes()
        app.push()
        root.update()
        assert app.job == "push"
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
    app, _ = make_app(root, monkeypatch, pages=BOARD_PAGES, push_fn=no_push)
    try:
        assert "留言檔無法讀取" in app.tiles[3].canvas.cget("text")
        dialog = app.open_notes()
        assert "notes file" in dialog.status.cget("text")
        dialog.text.insert("1.0", "hi")
        dialog.post()
        assert "無法儲存留言" in dialog.status.cget("text")
        assert note_store.notes_path().read_text(encoding="utf-8") == "{broken"
    finally:
        app.worker.close()


def test_sync_is_not_offered_when_only_board_card_and_photo_pages_exist(root, monkeypatch):
    app, errors = make_app(root, monkeypatch, pages={1: "photo", 2: "card", 3: "message", 4: "board"},
                           feeds_=ONE_FEED)
    try:
        assert str(app.sync_btn.cget("state")) == "disabled" and not errors
    finally:
        app.worker.close()


def test_message_board_texts_call_the_hardware_a_device(root, monkeypatch):
    app, _ = make_app(root, monkeypatch)
    try:
        dialog = app.open_notes()
        shown = "".join(widget_texts(dialog.win)) + app.notes_btn.cget("text")
        assert "留言" in shown and "裝置" in shown and "月曆" not in shown
        report = SyncReport(pages={3: "board"}, notes=1, results={3: UploadResult.OK})
        assert "月曆" not in gui.push_summary(report) and "月曆" not in strings.t("notes_no_board")
    finally:
        app.worker.close()


# --- choosing the photo crop -------------------------------------------------------

@pytest.fixture
def quick_dither(monkeypatch):
    """Previews and the expected frames both use plain nearest-colour mapping: these tests are about the crop."""
    monkeypatch.setattr(gui.image, "stucki", lambda img, strength=1.0: gui.image.to_indexed(img, dither=False).tobytes())


def wide_photo(tmp_path, name="wide.png"):
    path = tmp_path / name
    img = Image.new("RGB", (1600, 480), "red")
    img.paste((0, 0, 200), (800, 0, 1600, 480))
    img.save(path)
    return str(path)


def expected_frame(path, crop=None, fit="cover"):
    with gui.image.open_image(path) as src:
        return gui.image.encode(src, fit, crop=crop, strength=1.0)


def ready_tile(app, root, path, slot=1):
    tile = app.tiles[slot]
    tile.set_path(path)
    pump(root, lambda: tile.frame is not None)
    return tile


def test_adjust_crop_button_enabled_only_with_photo_in_fill(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        tile = app.tiles[1]
        assert str(tile.adjust_btn.cget("state")) == "disabled"  # no photo
        assert tile.adjust_crop() is None
        ready_tile(app, root, wide_photo(tmp_path))
        assert str(tile.adjust_btn.cget("state")) == "normal"
        app.fit.set("contain")
        app.rerender()
        assert str(tile.adjust_btn.cget("state")) == "disabled"  # Fit shows the whole photo
        assert tile.adjust_crop() is None
        app.fit.set("cover")
        app.rerender()
        assert str(tile.adjust_btn.cget("state")) == "normal"
    finally:
        app.worker.close()


def test_crop_dialog_ok_sets_crop_and_rerenders(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        path = wide_photo(tmp_path)
        tile = ready_tile(app, root, path)
        centre = tile.frame
        dialog = tile.adjust_crop()
        assert dialog is not None and dialog.photo_size == (1600, 480)
        dialog.drag(100, 0)
        assert dialog.crop[0] > 0.2
        dialog.ok()
        assert tile.crop is not None and tile.dialog is None and not dialog.win.winfo_exists()
        pump(root, lambda: tile.frame is not None)
        assert tile.frame == expected_frame(path, tile.crop) != centre
        assert app.frames() == {1: tile.frame}
    finally:
        app.worker.close()


def test_crop_dialog_controls_keep_the_crop_valid(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        tile = app.tiles[1]
        tile.path = wide_photo(tmp_path)
        dialog = tile.adjust_crop()
        dialog.set_zoom(2)
        assert gui.zoom_level(dialog.crop, dialog.photo_size) == pytest.approx(2)
        dialog.wheel(-1)
        dialog.key("Left", shift=True)
        dialog.drag_corner("se", 300, 120)
        dialog.drag(-5000, 5000)
        dialog.set_zoom(100)
        gui.image.check_crop(dialog.crop, *dialog.photo_size)
        assert gui.zoom_level(dialog.crop, dialog.photo_size) > 4
        dialog.cancel()
    finally:
        app.worker.close()


def test_crop_dialog_reset_gives_none(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        path = wide_photo(tmp_path)
        tile = ready_tile(app, root, path)
        dialog = tile.adjust_crop()
        dialog.drag(100, 0)
        dialog.ok()
        pump(root, lambda: tile.frame is not None)
        dialog = tile.adjust_crop()
        assert dialog.crop == tile.crop
        dialog.reset()
        dialog.ok()
        assert tile.crop is None
        pump(root, lambda: tile.frame is not None)
        assert tile.frame == expected_frame(path)
    finally:
        app.worker.close()


def test_crop_dialog_cancel_keeps_previous(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        tile = ready_tile(app, root, wide_photo(tmp_path))
        dialog = tile.adjust_crop()
        dialog.drag(100, 0)
        dialog.ok()
        pump(root, lambda: tile.frame is not None)
        chosen, frame = tile.crop, tile.frame
        dialog = tile.adjust_crop()
        dialog.drag(-300, 0)
        dialog.cancel()
        assert tile.crop == chosen and tile.frame == frame and tile.dialog is None
        assert not dialog.win.winfo_exists()
    finally:
        app.worker.close()


def test_new_photo_resets_crop_and_closes_dialog(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        tile = ready_tile(app, root, wide_photo(tmp_path))
        tile.crop = (0.1, 0.0, 0.5, 1.0)
        dialog = tile.adjust_crop()
        other = wide_photo(tmp_path, "other.png")
        tile.set_path(other)
        assert tile.crop is None and tile.dialog is None and not dialog.win.winfo_exists()
        pump(root, lambda: tile.frame is not None)
        assert tile.frame == expected_frame(other)
    finally:
        app.worker.close()


def test_fit_mode_ignores_then_restores_crop(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        path = wide_photo(tmp_path)
        tile = ready_tile(app, root, path)
        dialog = tile.adjust_crop()
        dialog.drag(100, 0)
        dialog.ok()
        pump(root, lambda: tile.frame is not None)
        crop = tile.crop
        for fit, want in (("contain", None), ("cover", crop)):
            app.fit.set(fit)
            app.rerender()
            pump(root, lambda: tile.frame is not None)
            assert tile.crop == crop  # kept while Fit ignores it
            assert tile.frame == expected_frame(path, want, fit) == app.frames()[1]
    finally:
        app.worker.close()


def test_large_photo_dialog_uses_downscaled_view(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        path = tmp_path / "big.jpg"
        Image.new("RGB", (6000, 4000), (120, 160, 80)).save(path)
        tile = app.tiles[1]
        tile.path = str(path)
        started = time.monotonic()
        dialog = tile.adjust_crop()
        assert time.monotonic() - started < 1
        assert dialog.view_image.width <= 1000
        assert dialog.photo_size == (3240, 2160)  # fractions are measured on the 4K-capped photo
        dialog.cancel()
    finally:
        app.worker.close()


def test_double_click_opens_crop_single_click_on_empty_chooses(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        asked = []
        monkeypatch.setattr(gui.filedialog, "askopenfilename", lambda **kw: asked.append(kw) or "")
        tile = app.tiles[1]
        assert "<Double-Button-1>" in tile.canvas.bind()
        tile.clicked()
        assert len(asked) == 1  # empty tile: one click chooses
        tile.double_clicked()
        assert tile.dialog is None
        ready_tile(app, root, wide_photo(tmp_path))
        tile.clicked()
        assert len(asked) == 1  # with a photo the first click of a double click must not open the chooser
        tile.double_clicked()
        assert tile.dialog is not None
        tile.dialog.cancel()
    finally:
        app.worker.close()


def test_crop_dialog_panorama_wider_than_4k_at_maximum_zoom_renders(root, monkeypatch, tmp_path, quick_dither):
    app, _ = make_app(root, monkeypatch)
    try:
        path = tmp_path / "pano.jpg"
        Image.new("RGB", (12000, 1000), (90, 140, 200)).save(path)
        tile = app.tiles[1]
        tile.set_path(str(path))
        pump(root, lambda: tile.frame is not None)
        dialog = tile.adjust_crop()
        assert dialog.photo_size == gui.image.open_image(str(path)).size == (3840, 320)
        dialog.set_zoom(8)  # the 100 px floor stops it at 3.2x: a crop 0.3125 high, not 0.125
        assert dialog.crop[3] == pytest.approx(0.3125)
        dialog.ok()
        pump(root, lambda: tile.frame is not None)
        assert tile.path == str(path) and not tile.status.cget("text").startswith("無法讀取")
        assert tile.frame == expected_frame(str(path), tile.crop)
    finally:
        app.worker.close()


# --- Chinese / English ---------------------------------------------------------


def test_toggle_label_is_the_other_language(root, monkeypatch):
    app, _ = make_app(root, monkeypatch)
    try:
        assert app.lang_btn.cget("text") == "English"
        app.lang_btn.invoke()
        assert strings.language() == "en" and app.lang_btn.cget("text") == "中文"
        app.lang_btn.invoke()
        assert strings.language() == "zh" and app.lang_btn.cget("text") == "English"
    finally:
        app.worker.close()


def test_toggle_switches_visible_texts(root, monkeypatch, tmp_path):
    app, _ = make_app(root, monkeypatch, feeds_=ONE_FEED)
    try:
        tile = app.tiles[1]
        tile.set_path(photo(tmp_path))
        pump(root, lambda: tile.frame is not None)
        feeds_dialog, notes_dialog, crop_dialog = app.open_feeds(), app.open_notes(), tile.adjust_crop()
        assert tile.box.cget("text") == "第 1 頁" and tile.combo.get() == "照片"
        assert feeds_dialog.win.title() == "行事曆來源" and crop_dialog.win.title() == "調整範圍"

        app.lang_btn.invoke()
        assert tile.box.cget("text") == "Page 1" and app.push_btn.cget("text") == "Push to device"
        assert tile.update_btn.cget("text") == "Update this page"
        assert notes_dialog.hint.cget("text") == ("Notes reach the device when you click “Push to device”, "
                                                  "or “Update this page” on a notes page.")
        assert list(tile.combo.cget("values")) == ["Photo", "Today + month", "Today + week", "To-do", "Day",
                                                   "Month", "Notes board", "Big message", "Card"]
        assert tile.combo.get() == "Photo"
        assert list(app.grain_box.cget("values")) == ["Standard", "Soft", "Softer", "Smoothest"]
        assert app.grain_box.get() == "Standard"
        assert tile.status.cget("text") == "Preview in the device\u2019s 7 colours"
        assert app.device.cget("text") == "Device status: not read yet"
        assert app.feeds_label.cget("text") == "Calendar sources: 個人"  # the feed's own name stays
        assert (notes_dialog.win.title(), feeds_dialog.win.title(), crop_dialog.win.title()) == (
            "Notes", "Calendar sources", "Adjust crop")

        app.lang_btn.invoke()
        assert tile.box.cget("text") == "第 1 頁" and tile.combo.get() == "照片"
        assert (notes_dialog.win.title(), feeds_dialog.win.title(), crop_dialog.win.title()) == (
            "留言", "行事曆來源", "調整範圍")

        app.lang_btn.invoke()  # choosing by the English names picks the right kind and grain
        tile.combo.set("Month")
        tile._kind_chosen()
        assert tile.kind == "monthgrid" and config.load().pages[1] == "monthgrid"
        app.grain_box.set("Soft")
        app.grain_chosen()
        assert app.grain.get() == "柔和"
        app.lang_btn.invoke()
        assert tile.combo.get() == "月曆" and app.grain_box.get() == "柔和"
    finally:
        app.worker.close()


def test_the_page_kind_box_shows_every_name_whole_in_either_language(root, monkeypatch):
    app, _ = make_app(root, monkeypatch)
    try:
        combo = app.tiles[1].combo

        def measure(text):
            return int(root.tk.call("font", "measure", combo.cget("font"), "-displayof", combo, text))

        for lang, longest in (("zh", "本日行程＋一週行程"), ("en", "Today + month"), ("zh", "本日行程＋一週行程")):
            app.set_language(lang)
            room = int(combo.cget("width")) * measure("0")  # an entry's width counts the font's "0"s
            assert all(measure(name) <= room for name in combo.cget("values")), lang
            assert longest in combo.cget("values")
    finally:
        app.worker.close()


def test_language_persists_in_settings(root, monkeypatch):
    app, _ = make_app(root, monkeypatch)
    try:
        app.set_language("en")
        assert config.load().language == "en"
        second = tk.Toplevel(root)
        second.withdraw()
        strings.set_language("zh")  # a new launch starts from the saved choice, not from the last one
        other = gui.App(second, calendar_ok_fn=lambda: True, secrets=MemorySecrets())
        try:
            assert strings.language() == "en" and other.lang_btn.cget("text") == "中文"
            assert other.push_btn.cget("text") == "Push to device"
        finally:
            other.worker.close()
    finally:
        app.worker.close()


def test_without_a_saved_choice_the_app_follows_the_system_language(root, monkeypatch):
    monkeypatch.setattr(strings, "system_language", lambda: "en")
    app, _ = make_app(root, monkeypatch)
    try:
        assert strings.language() == "en" and app.lang_btn.cget("text") == "中文"
        assert config.load().language is None  # only an explicit click is remembered
    finally:
        app.worker.close()


def test_switch_during_push_keeps_buttons_disabled(root, monkeypatch, tmp_path):
    release = threading.Event()
    app, _ = make_app(root, monkeypatch, push_fn=slow_push(release))
    try:
        app.tiles[1].set_path(photo(tmp_path))
        pump(root, lambda: str(app.push_btn.cget("state")) == "normal")
        app.push()
        root.update()
        app.set_language("en")
        assert app.summary.cget("text") == "Connecting and pushing\u2026 (the page on screen goes last)"
        assert app.tiles[1].status.cget("text") == "Waiting"
        assert str(app.push_btn.cget("state")) == str(app.info_btn.cget("state")) == "disabled"
        assert {str(w.cget("state")) for w in app.option_widgets} == {"disabled"}
        assert str(app.tiles[1].combo.cget("state")) == "disabled"
        release.set()
        pump(root, lambda: app.summary.cget("text").startswith("Done"))
        assert app.summary.cget("text") == "Done: 1 page updated, 0 pages already the same."
    finally:
        release.set()
        app.worker.close()


def test_language_switch_relabels_a_tile_that_shows_a_photo_error(root, monkeypatch, tmp_path):
    from test_image import header_only_png

    big = header_only_png(tmp_path / "big.png", 8000, 8000)  # 64 MP: over the 50 MP limit
    bad = tmp_path / "x.jpg"
    bad.write_text("not an image")
    opened = []
    real_open = gui.image.open_image
    monkeypatch.setattr(gui.image, "open_image", lambda *a, **kw: opened.append(a) or real_open(*a, **kw))
    app, _ = make_app(root, monkeypatch)
    try:
        tile = app.tiles[1]
        tile.set_path(str(big))
        pump(root, lambda: "照片超過" in tile.status.cget("text"))
        decodes = len(opened)
        app.set_language("en")
        assert tile.status.cget("text") == "This photo is over the 50-megapixel limit. Shrink it, then choose it again."
        assert tile.canvas.cget("text") == "Can\u2019t read this file"
        app.set_language("zh")
        assert tile.status.cget("text") == "照片超過 5000 萬像素的上限，請先縮小再選。"
        assert tile.canvas.cget("text") == "無法讀取這個檔案"

        tile.set_path(str(bad))
        pump(root, lambda: "x.jpg" in tile.status.cget("text"))
        zh = tile.status.cget("text")
        assert zh.startswith("無法讀取 x.jpg：")
        decodes = len(opened)
        app.set_language("en")
        assert tile.status.cget("text").startswith("Can\u2019t read x.jpg: ")
        assert tile.canvas.cget("text") == "Can\u2019t read this file"
        app.set_language("zh")
        assert tile.status.cget("text") == zh and tile.path is None
        assert len(opened) == decodes  # switching never decodes a photo again
    finally:
        app.worker.close()


def test_feed_form_keeps_its_colour_when_the_language_changes(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, feeds_=ONE_FEED)  # the feed is blue
    try:
        dialog = app.open_feeds()
        dialog.tree.selection_set("p1")
        form = dialog.edit()
        assert form.win.title() == "編輯「個人」" and form.colour.get() == "藍"
        app.set_language("en")
        assert form.win.title() == "Edit “個人”" and form.colour.get() == "Blue"
        assert dialog.tree.item("p1", "values")[1] == "Blue" and form.colour_value() == "blue"
        form.colour.set("Green")  # picked by its English name
        app.set_language("zh")
        assert form.colour.get() == "綠" and form.colour_value() == "green"
    finally:
        app.worker.close()


def test_a_card_page_says_how_to_fill_it_not_to_sync(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages={1: "photo", 2: "card", 3: "month", 4: "photo"})
    try:
        shown = widget_texts(app.tiles[2].box) + [str(app.tiles[2].canvas.cget("text"))]
        assert any("我的牌卡" in t for t in shown)
        assert not any("立即同步" in t or "行事曆來源" in t for t in shown)
    finally:
        app.worker.close()


def test_the_grain_is_kept_in_the_settings_for_the_scheduled_sync_and_the_next_run(root, monkeypatch):
    app, _ = make_app(root, monkeypatch)
    try:
        app.grain_box.set("最平滑")
        app.grain_chosen()
        assert config.load().grain == 0.5
    finally:
        app.worker.close()
    app = gui.App(root, calendar_ok_fn=lambda: True, secrets=MemorySecrets({}))  # reopened: reads the saved settings
    try:
        assert app.grain.get() == "最平滑"
    finally:
        app.worker.close()


# --- calendar page backgrounds ------------------------------------------------------------

def test_a_calendar_page_gets_a_background_photo_that_can_be_cropped_and_removed(root, monkeypatch, tmp_path,
                                                                              quick_dither):
    from test_image import header_only_png

    app, errors = make_app(root, monkeypatch, pages={1: "month", 2: "agenda", 3: "todo", 4: "photo"})
    try:
        tile = app.tiles[1]
        assert tile.bg_btn.cget("text") == "底圖…"
        assert str(tile.bg_btn.cget("state")) == "normal" and str(app.tiles[4].bg_btn.cget("state")) == "disabled"
        app.calendar_images[1] = ("month", Image.new("RGB", (800, 480), "white"))  # drawn on the old background

        big = header_only_png(tmp_path / "big.png", 8000, 8000)  # over 50 MP: refused, nothing saved
        monkeypatch.setattr(gui.filedialog, "askopenfilename", lambda **kw: str(big))
        tile.choose_background()
        assert tile.status.cget("text") == strings.t("photo_too_large") and not config.load().backgrounds

        monkeypatch.setattr(gui.filedialog, "askopenfilename", lambda **kw: wide_photo(tmp_path))
        tile.choose_background()
        stored = config.backgrounds_dir() / "page-1.jpg"
        assert config.load().backgrounds == {1: config.PageBackground("page-1.jpg")} and stored.exists()
        assert 1 not in app.calendar_images
        pump(root, lambda: str(tile.canvas.cget("image")) != str(tile.blank))  # the preview shows the photo
        assert "立即同步" in tile.canvas.cget("text")

        dialog = tile.adjust_background()  # the photo pages' crop dialog, on the stored copy
        assert dialog.photo_size == (1600, 480)
        dialog.wheel(3)
        dialog.ok()
        crop = config.load().backgrounds[1].crop
        assert crop is not None and crop == pytest.approx(dialog.crop) and tile.dialog is None
        pump(root, lambda: str(tile.canvas.cget("image")) != str(tile.blank))  # done reading the copy

        tile.clear_background()
        assert config.load().backgrounds == {} and not stored.exists()
        assert str(tile.canvas.cget("image")) == str(tile.blank)
        assert not errors
    finally:
        app.worker.close()


# --- cards --------------------------------------------------------------------------------

from ulani_epaper import cards  # noqa: E402
from ulani_epaper.cards import Background, Card, TextBox  # noqa: E402


def saved_card(text, colour="yellow"):
    return cards.add(Card(background=Background(colour), texts=(TextBox(text, (0.1, 0.1, 0.8, 0.5)),)))


def open_cards(app, root):
    window = app.open_cards()
    pump(root, lambda: all(app.card_drawing(c) for c in cards.load()))
    return window


def test_a_card_is_put_on_a_card_page_and_sent_by_the_next_push(root, monkeypatch):
    calls = []
    quote, status = saved_card("今日名言"), saved_card("開會中", "red")  # newest first: status, quote
    app, errors = make_app(root, monkeypatch, pages={1: "month", 2: "card", 3: "photo", 4: "photo"},
                           push_fn=fake_push(calls))
    try:
        assert app.cards_btn.cget("text") == "我的牌卡…"
        window = open_cards(app, root)
        assert window.win.title() == "我的牌卡" and list(window.cells) == [status.id, quote.id]
        put = window.cells[quote.id][2]
        assert put.cget("text") == "放到第 2 頁" and window.where(quote) == "沒有放在任何一頁"
        tile = app.tiles[2]
        assert tile.canvas.cget("text") != "" and str(tile.update_btn.cget("state")) == "disabled"  # none chosen
        put.invoke()
        assert config.load().card_choice == {2: quote.id} and window.where(quote) == "放在第 2 頁"
        assert window.status.cget("text") == "已放到第 2 頁，按主視窗的「推送到裝置」或那一頁的「更新這頁」送到裝置。"
        root.update()
        assert calls == [] and app.job is None  # nothing goes to the device yet
        assert tile.canvas.cget("text") == "" and str(tile.update_btn.cget("state")) == "normal"  # shows the card
        tile.update_btn.invoke()
        pump(root, lambda: app.job is None)
        assert calls[0]["only"] == 2 and calls[0]["card_choice"] == {2: quote.id}
        assert config.load().card_pages == {2: "pushed"}  # what the push left on the card pages
        assert not errors
    finally:
        app.worker.close()


def test_with_several_card_pages_a_menu_picks_the_page(root, monkeypatch):
    card = saved_card("暫離")
    menus = []
    monkeypatch.setattr(gui.tk.Menu, "tk_popup", lambda self, x, y: menus.append(self))
    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: True)
    app, errors = make_app(root, monkeypatch, pages={1: "card", 2: "photo", 3: "card", 4: "photo"}, push_fn=no_push)
    try:
        window = open_cards(app, root)
        put = window.cells[card.id][2]
        assert put.cget("text") == "放到…"
        put.invoke()
        (menu,) = menus
        assert [menu.entrycget(i, "label") for i in range(menu.index("end") + 1)] == ["放到第 1 頁", "放到第 3 頁"]
        menu.invoke(1)
        assert config.load().card_choice == {3: card.id} and window.where(card) == "放在第 3 頁"
        app.set_kind(3, "photo")  # no longer a card page: its card drops out
        assert config.load().card_choice == {} and put.cget("text") == "放到第 1 頁"
        put.invoke()
        assert config.load().card_choice == {1: card.id} and str(app.tiles[1].update_btn.cget("state")) == "normal"
        window.ticked[card.id].set(True)
        window.delete()  # a deleted card drops out too
        assert cards.load() == [] and config.load().card_choice == {}
        assert str(app.tiles[1].update_btn.cget("state")) == "disabled"
        assert not errors
    finally:
        app.worker.close()


def test_a_card_page_shows_its_card_as_edited(root, monkeypatch):
    card = saved_card("暫離")
    app, errors = make_app(root, monkeypatch, pages={1: "card", 2: "photo", 3: "photo", 4: "photo"}, push_fn=no_push)
    shown = []
    monkeypatch.setattr(app.tiles[1], "show_calendar", shown.append)
    try:
        window = open_cards(app, root)
        window.put(card, 1)
        assert shown[-1].tobytes() == layouts.render_card(card).tobytes()
        editor = window.edit_card(card)
        window.win.destroy()  # the editor outlives My cards
        editor.set_colour("blue")
        edited = editor.save()
        pump(root, lambda: shown[-1].tobytes() == layouts.render_card(edited).tobytes())
        assert not errors
    finally:
        app.worker.close()


@pytest.mark.parametrize("answer", [True, False])
def test_without_a_card_page_one_confirmation_turns_the_photo_page_into_one(root, monkeypatch, answer):
    asked = []
    card = saved_card("暫離")
    app, errors = make_app(root, monkeypatch, pages=DEFAULT, push_fn=no_push)
    monkeypatch.setattr(gui.messagebox, "askyesno", lambda title, text, **kw: asked.append(text) or answer)
    try:
        window = open_cards(app, root)
        put = window.cells[card.id][2]
        assert put.cget("text") == "放到…"
        put.invoke()
        assert len(asked) == 1 and "第 4 頁（照片）" in asked[0] and "放上去" in asked[0]
        if answer:
            assert config.load().pages[4] == "card" and app.tiles[4].kind == "card"
            assert config.load().card_choice == {4: card.id} and put.cget("text") == "放到第 4 頁"
        else:
            assert config.load().pages[4] == "photo" and config.load().card_choice == {}
        assert app.job is None and not errors
    finally:
        app.worker.close()


def test_the_card_editor_builds_a_card_with_a_live_preview(root, monkeypatch):
    app, errors = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        window = app.open_cards()
        editor = window.new()
        assert editor.win.title() == "新增牌卡"
        editor.set_colour("blue")
        editor.add_text()
        editor.set_text("開會中\n15:00 回來")
        editor.move(0.1, 0.0)
        editor.drag_corner("se", 0.95, 0.9)
        editor.set_size(80)
        editor.set_ink("yellow")
        editor.set_outline(True)
        editor.set_align("left")
        assert editor.preview.tobytes() == layouts.render_card(editor.card()).tobytes()  # live, in panel colours
        editor.add_text()
        editor.delete_text()
        saved = editor.save()
        assert not editor.win.winfo_exists()
        (stored,) = cards.load()
        assert stored == saved and stored.background == Background("blue")
        (box,) = stored.texts
        assert (box.text, box.size, box.color, box.outline, box.outline_color, box.align) == (
            "開會中\n15:00 回來", 80, "yellow", True, "black", "left")
        assert box.box[0] + box.box[2] == pytest.approx(0.95) and box.box[1] + box.box[3] == pytest.approx(0.9)
        assert list(window.cells) == [stored.id]
        assert not errors
    finally:
        app.worker.close()


def test_the_editor_outlives_the_cards_window_and_saves_into_the_one_open_now(root, monkeypatch):
    app, errors = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        editor = app.open_cards().new()
        app.cards_window.win.destroy()  # My cards closed, the editor still open
        editor.add_text()
        editor.set_text("開會中")
        reopened = app.open_cards()
        assert reopened.new() is editor  # still the one editor, from the new window too
        saved = editor.save()
        assert saved is not None and cards.load() == [saved]
        assert list(reopened.cells) == [saved.id]
        reopened.win.destroy()
        editor = app.open_cards().new()
        app.cards_window.win.destroy()
        editor.add_text()
        editor.set_text("再見")
        assert editor.save() is not None and len(cards.load()) == 2  # saved with no window to refresh
        assert not errors
    finally:
        app.worker.close()


def test_the_card_editor_explains_what_cannot_be_saved(root, monkeypatch):
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        editor = app.open_cards().new()
        editor.add_text()
        editor.set_text("  ")
        assert editor.save() is None and editor.status.cget("text") == "第 1 個文字框是空的"
        editor.set_text("字" * 81)
        assert editor.save() is None and editor.status.cget("text") == "第 1 個文字框最多 80 字（目前 81 字）"
        for _ in range(cards.MAX_TEXTS):
            editor.add_text()
        assert len(editor.texts) == cards.MAX_TEXTS and editor.status.cget("text") == "每張牌卡最多 8 個文字框"
        assert cards.load() == []
    finally:
        app.worker.close()


def test_the_card_editor_takes_a_photo_and_its_crop(root, monkeypatch, tmp_path, quick_dither):
    app, errors = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        window = app.open_cards()
        editor = window.new()
        path = wide_photo(tmp_path)
        monkeypatch.setattr(gui.filedialog, "askopenfilename", lambda **kw: path)
        editor.choose_photo()
        editor.add_text()
        dialog = editor.adjust_photo()
        assert dialog.photo_size == (1600, 480)  # cropped from the whole (capped) photo
        dialog.wheel(3)
        dialog.ok()
        pump(root, lambda: editor.background is not None)
        expected = layouts.load_background("wide.png", editor.crop, tmp_path)
        assert editor.background.tobytes() == expected.tobytes()
        assert editor.preview.tobytes() == layouts.render_card(editor.card(), background=expected).tobytes()
        saved = editor.save()
        assert saved.background.image == f"{saved.id}.jpg" and saved.background.crop == pytest.approx(editor.crop)
        assert (cards.backgrounds_dir() / saved.background.image).exists()
        editor = window.edit_card(saved)  # opened again: the stored photo and crop
        assert editor.win.title() == "編輯牌卡" and editor.crop == saved.background.crop
        assert editor.photo == str(cards.backgrounds_dir() / saved.background.image)
        assert not errors
    finally:
        app.worker.close()


def test_duplicate_delete_export_and_import_cards(root, monkeypatch, tmp_path):
    card = saved_card("請勿打擾")
    app, errors = make_app(root, monkeypatch, pages=DEFAULT)
    monkeypatch.setattr(gui.messagebox, "askyesno", lambda *a, **kw: True)
    try:
        window = app.open_cards()
        window.duplicate()
        assert window.status.cget("text") == "請先勾選一張牌卡。"
        window.ticked[card.id].set(True)
        window.duplicate()
        assert [c.texts for c in cards.load()] == [card.texts, card.texts] and len(window.cells) == 2
        target = tmp_path / "status.paperhue-card"
        monkeypatch.setattr(gui.filedialog, "asksaveasfilename", lambda **kw: str(target))
        window.ticked[card.id].set(True)
        window.export()
        assert target.exists() and "status.paperhue-card" in window.status.cget("text")
        for var in window.ticked.values():
            var.set(True)
        window.delete()
        assert cards.load() == [] and not window.cells
        monkeypatch.setattr(gui.filedialog, "askopenfilename", lambda **kw: str(target))
        window.import_()
        (imported,) = cards.load()
        assert imported.texts == card.texts and list(window.cells) == [imported.id]
        assert not errors
    finally:
        app.worker.close()


def test_the_cards_window_and_the_editor_follow_the_language(root, monkeypatch):
    saved_card("Away")
    app, _ = make_app(root, monkeypatch, pages=DEFAULT)
    try:
        window = open_cards(app, root)
        editor = window.new()
        app.lang_btn.invoke()
        assert (window.win.title(), editor.win.title()) == ("My cards", "New card")
        put = window.cells[cards.load()[0].id][2]
        assert put.cget("text") == "Put on…" and app.cards_btn.cget("text") == "My cards…"
        assert app.tiles[1].bg_btn.cget("text") == "Background…"
        assert window.where(cards.load()[0]) == "Not on a page"
    finally:
        app.worker.close()
