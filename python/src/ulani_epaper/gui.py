"""Paperhue, the desktop app: photos, calendar / to-do pages and a message board for the device (``paperhue``).

tkinter only (ships with Python). Bluetooth runs on a BleWorker thread; the
Tk thread only reads a queue. Each of the four pages shows a photo, a month
calendar, a week agenda, a to-do list, the message board (sticky notes) or
the newest note in large type (saved in the settings). Calendar pages come
from the user's own iCal addresses ("feeds"); their data is fetched, drawn
and pushed in memory only. The notes are the owner's own words, kept in
notes.json (notes.py) and drawn locally, without any network.
UI text is Traditional Chinese on purpose: the device is sold in Taiwan.
"""

from __future__ import annotations

import copy
import os
import queue
import sys
import threading
import tkinter as tk
from datetime import datetime
from tkinter import filedialog, messagebox, ttk
from typing import Any, Awaitable, Callable

from bleak.exc import BleakError
from PIL import Image, ImageTk, UnidentifiedImageError

from . import config, feeds, image, layouts, push, schedule, sync, syncjob
from . import notes as note_store
from .agenda import LOCAL
from .client import DeviceBusy, NoReply, PushEvent, UploadFailed, UploadResult, connect
from .config import BOARD_KINDS, CALENDAR_KINDS, PAGE_KINDS, PAGE_NAMES
from .gui_model import BleWorker, describe, parse_times
from .protocol import USER_SLOTS, UlaniError

#: Largest preview size (5:3, like the panel).
THUMB = (384, 230)
#: Smallest preview height used on short screens.
MIN_THUMB_HEIGHT = 96
#: Vertical pixels (at 96 dpi) the OS takes outside the window: taskbar + title bar.
RESERVED = 80
#: Window height (at 96 dpi) not taken by the two rows of previews.
OVERHEAD = 520
IMAGE_TYPES = [("圖片", "*.jpg *.jpeg *.png *.bmp *.gif *.webp *.tif *.tiff"), ("所有檔案", "*.*")]
FEEDS_HELP = ("每個來源是一個 iCal（.ics）網址，例如 Google 日曆每個日曆的「iCal 格式的私密網址」"
              "（日曆設定 → 整合日曆）。網址只存在這台電腦的 Windows 認證管理員；程式只讀取，"
              "也不會把行程內容存在電腦上。說明：docs/CALENDARS.md")
#: feed colour -> label in the colour picker
COLOUR_NAMES = {"": "自動", "red": "紅", "orange": "橙", "yellow": "黃", "green": "綠", "blue": "藍", "black": "黑"}
#: note colour -> label in the message dialog, in the order shown
NOTE_COLOUR_NAMES = {"yellow": "黃", "orange": "橘", "green": "綠", "blue": "藍", "red": "紅"}
NO_BOARD_HELP = ("還沒有留言頁：請在主視窗任一頁的「顯示」選「留言板」或「大字留言」，"
                 "留言就會顯示在裝置的那一頁。")

PushFn = Callable[[dict, Callable[[PushEvent], None]], Awaitable[dict]]
InfoFn = Callable[[], Awaitable[dict]]
SyncFn = Callable[[config.Settings, Callable[[PushEvent], None], Callable[[dict], None]],
                  Awaitable[sync.SyncReport]]
#: post_fn(settings, show, progress, rendered): push the message board pages (see sync.post)
PostFn = Callable[[config.Settings, str, Callable[[PushEvent], None], Callable[[dict], None]],
                  Awaitable[sync.SyncReport]]


async def default_push(frames: dict[int, bytes], progress: Callable[[PushEvent], None]) -> dict:
    return await push.push_frames(frames, progress=progress)


async def default_info() -> dict:
    async with connect() as cal:
        battery = await cal.battery()
        shown, _ = await cal.current_slot()
        return {"battery": battery, "shown": shown}


async def default_sync(settings: config.Settings, progress: Callable[[PushEvent], None],
                       rendered: Callable[[dict], None]) -> sync.SyncReport:
    return await sync.sync(settings, progress=progress, on_rendered=rendered)


async def default_post(settings: config.Settings, show: str, progress: Callable[[PushEvent], None],
                       rendered: Callable[[dict], None]) -> sync.SyncReport:
    return await sync.post(settings, show=show, progress=progress, on_rendered=rendered)


def default_calendar_ok() -> bool:
    """Whether the optional packages for the calendar pages are installed."""
    try:
        import icalendar  # noqa: F401
        import keyring  # noqa: F401
    except ModuleNotFoundError:
        return False
    return True


def thumb_size(screen_height: int, overhead: int = OVERHEAD, reserved: int = RESERVED) -> tuple[int, int]:
    """Largest 5:3 preview such that the window fits a screen this tall.

    ``overhead`` is the window height not taken by the two rows of previews;
    ``reserved`` is what the taskbar and title bar take.
    """
    h = max(MIN_THUMB_HEIGHT, min(THUMB[1], (screen_height - reserved - overhead) // 2))
    return THUMB if h == THUMB[1] else (round(h * 5 / 3), h)


def friendly(error: BaseException) -> str:
    """A short explanation in Chinese, followed by the technical message."""
    text = str(error) or type(error).__name__
    if isinstance(error, feeds.NoFeeds):
        hint = "還沒有行事曆來源：請按「行事曆來源…」加入 iCal 網址。"
    elif isinstance(error, feeds.FeedError):
        hint = "無法讀取行事曆來源。請確認網路連線；如果網址已重設，請在「行事曆來源…」更新。"
    elif "Insufficient Authentication" in text or "Insufficient Encryption" in text:
        hint = "裝置尚未與這台電腦配對。請按住裝置按鍵約 5 秒（綠燈閃爍）後，在 Windows 藍牙設定中配對。"
    elif isinstance(error, (DeviceBusy, NoReply)):
        hint = "裝置沒有回應（可能正在刷新畫面）。請等一分鐘後再推送一次。"
    elif isinstance(error, UploadFailed):
        hint = "裝置回報收到的資料有誤，請再推送一次。"
    elif "no e-paper device found" in text or "could not connect" in text:
        hint = ("找不到裝置或連不上。請確認：裝置在附近、藍牙已開啟、"
                "裝置已與這台電腦配對，且沒有其他手機或電腦正在連線。")
    elif isinstance(error, (BleakError, OSError)):
        hint = "藍牙連線中斷。請靠近裝置後再推送一次。"
    else:
        return text
    return f"{hint}\n\n{text}"


def post_summary(report: sync.SyncReport) -> str:
    """The status line after the message board pages were pushed."""
    text = f"留言已送到裝置：{syncjob.describe(report)}"
    return text + (f"。裝置顯示第 {report.show} 頁。" if report.show else "。")


def preview_error_text(name: str, error: BaseException) -> str:
    if isinstance(error, UnidentifiedImageError):
        reason = "不支援的檔案格式（HEIC 請先轉成 JPG）"
    elif isinstance(error, UlaniError) and "too large" in str(error):
        reason = "圖片太大"
    elif isinstance(error, OSError):
        reason = "檔案無法開啟或已損壞"
    else:
        reason = "無法處理這個檔案"
    return f"無法讀取 {name}：{reason}"


class Tile:
    """One page: what it shows, the chosen photo or the last calendar drawing,
    preview widget, progress."""

    def __init__(self, parent: tk.Widget, slot: int, app: "App", thumb: tuple[int, int], kind: str) -> None:
        self.slot, self.app, self.kind = slot, app, kind
        self.path: str | None = None
        self.frame: bytes | None = None  # the encoded photo (photo pages only)
        self.generation = 0
        self.photo: ImageTk.PhotoImage | None = None

        self.box = ttk.LabelFrame(parent, text=f"第 {slot} 頁", padding=8)
        top = ttk.Frame(self.box)
        top.grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 6))
        ttk.Label(top, text="顯示").pack(side="left")
        self.combo = ttk.Combobox(top, values=[PAGE_NAMES[k] for k in PAGE_KINDS], state="readonly", width=10)
        self.combo.set(PAGE_NAMES[kind])
        self.combo.pack(side="left", padx=(6, 0))
        self.combo.bind("<<ComboboxSelected>>", self._kind_chosen)
        self.canvas = tk.Label(self.box, bg="#e8e8e8", fg="#666", compound="center", justify="center")
        self.canvas.grid(row=1, column=0, columnspan=3)  # centred, never stretched
        self.canvas.bind("<Button-1>", lambda e: self.clicked())
        self.name = ttk.Label(self.box, text="", width=40)
        self.name.grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 2))
        self.pick = ttk.Button(self.box, text="選擇照片…", command=self.choose)
        self.pick.grid(row=3, column=0, sticky="w")
        self.clear_btn = ttk.Button(self.box, text="清除", command=self.clear)
        self.clear_btn.grid(row=3, column=1, sticky="w", padx=6)
        self.bar = ttk.Progressbar(self.box, maximum=100, length=160)
        self.bar.grid(row=3, column=2, sticky="e")
        self.status = ttk.Label(self.box, text="", foreground="#555")
        self.status.grid(row=4, column=0, columnspan=3, sticky="w", pady=(4, 0))
        self.resize(thumb)

    def _kind_chosen(self, _event=None) -> None:
        kind = next(k for k in PAGE_KINDS if PAGE_NAMES[k] == self.combo.get())
        if kind != self.kind:
            self.app.set_kind(self.slot, kind)

    def resize(self, thumb: tuple[int, int]) -> None:
        self.thumb = thumb
        self.blank = ImageTk.PhotoImage(Image.new("RGB", thumb, (232, 232, 232)))
        self.canvas.configure(width=thumb[0], height=thumb[1], image=self.blank)
        self.status.configure(wraplength=thumb[0])
        self.show_content()

    def set_kind(self, kind: str) -> None:
        self.kind = kind
        self.combo.set(PAGE_NAMES[kind])
        self.set_progress("", 0)
        self.show_content()

    def clicked(self) -> None:
        if self.kind in BOARD_KINDS:
            self.app.open_notes()
        else:
            self.choose()

    def show_content(self) -> None:
        """Show the photo preview, the latest calendar drawing, or (message
        board pages) the drawing from the saved notes."""
        if self.kind == "photo":
            self.name.configure(text=os.path.basename(self.path) if self.path else "")
            if self.path:
                self.render()
            else:
                self.canvas.configure(image=self.blank, text="尚未選擇照片")
            return
        self.generation += 1  # drop a photo preview still being computed
        self.frame = None
        if self.kind in BOARD_KINDS:
            self.name.configure(text=f"{PAGE_NAMES[self.kind]}（按上方「留言…」張貼）")
            drawing = self.app.board_drawing(self.kind)
            if drawing is None:
                self.canvas.configure(image=self.blank, text="留言檔無法讀取\n\n請按上方「留言…」查看")
            else:
                self.show_calendar(drawing)
            return
        self.name.configure(text=f"{PAGE_NAMES[self.kind]}（來自行事曆來源）")
        drawn = self.app.calendar_images.get(self.slot)
        if drawn and drawn[0] == self.kind:
            self.show_calendar(drawn[1])
        else:
            self.canvas.configure(image=self.blank, text=f"{PAGE_NAMES[self.kind]}\n\n按上方「立即同步」更新")

    def choose(self) -> None:
        if self.app.worker.busy or self.kind != "photo":
            return
        path = filedialog.askopenfilename(title=f"選擇第 {self.slot} 頁的照片", filetypes=IMAGE_TYPES)
        if path:
            self.set_path(path)

    def set_path(self, path: str) -> None:
        self.path = path
        self.name.configure(text=os.path.basename(path))
        self.render()

    def clear(self) -> None:
        if self.app.worker.busy or self.kind != "photo":
            return
        self.path, self.frame = None, None
        self.generation += 1
        self.canvas.configure(image=self.blank, text="尚未選擇照片")
        self.name.configure(text="")
        self.set_progress("", 0)
        self.app.update_buttons()

    def render(self) -> None:
        """(Re)compute the 7-colour photo preview on a background thread."""
        if not self.path or self.kind != "photo":
            return
        self.generation += 1
        gen, path, thumb_size_ = self.generation, self.path, self.thumb
        fit = self.app.fit.get()
        strength = image.GRAIN.get(self.app.grain.get(), 1.0)
        self.frame = None
        self.set_progress("產生預覽中…", 0)
        self.app.update_buttons()

        def work() -> None:
            with self.app.preview_slots:  # at most two decodes at a time
                if gen != self.generation:
                    return  # superseded while waiting
                try:
                    with image.open_image(path) as src:
                        frame = image.encode(src, fit_mode=fit, strength=strength)
                    thumb = image.preview(frame).resize(thumb_size_, Image.LANCZOS)
                    self.app.inbox.put(("preview", self.slot, gen, frame, thumb))
                except Exception as e:  # unreadable file etc.
                    self.app.inbox.put(("preview-error", self.slot, gen, e, os.path.basename(path)))

        threading.Thread(target=work, daemon=True).start()

    def show_preview(self, gen: int, frame: bytes, thumb: Image.Image) -> None:
        if gen != self.generation or self.kind != "photo":
            return  # superseded by a newer choice, option change or page kind
        self.frame = frame
        self.photo = ImageTk.PhotoImage(thumb)
        self.canvas.configure(image=self.photo, text="")
        self.set_progress("預覽為裝置實際顯示的 7 色效果", 0)

    def show_preview_error(self, gen: int, error: BaseException, name: str) -> None:
        if gen != self.generation:
            return
        self.path, self.frame = None, None
        self.canvas.configure(image=self.blank, text="無法讀取這個檔案")
        self.name.configure(text="")
        self.set_progress(preview_error_text(name, error), 0)

    def show_calendar(self, drawing: Image.Image) -> None:
        self.photo = ImageTk.PhotoImage(drawing.resize(self.thumb, Image.LANCZOS))
        self.canvas.configure(image=self.photo, text="")

    def set_progress(self, text: str, percent: int) -> None:
        self.status.configure(text=text)
        self.bar.configure(value=percent)


class App:
    def __init__(self, root: tk.Misc, *, push_fn: PushFn = default_push, info_fn: InfoFn = default_info,
                 sync_fn: SyncFn = default_sync, post_fn: PostFn = default_post,
                 calendar_ok_fn: Callable[[], bool] = default_calendar_ok,
                 secrets: feeds.SecretStore | None = None, probe_fn: Callable[..., Any] | None = None,
                 schedule_install_fn: Callable[[list[str]], None] = schedule.install,
                 schedule_remove_fn: Callable[[], bool] = schedule.remove,
                 schedule_status_fn: Callable[[], dict | None] = schedule.status,
                 worker: BleWorker | None = None, thumb: tuple[int, int] | None = None) -> None:
        self.root, self.push_fn, self.info_fn, self.sync_fn = root, push_fn, info_fn, sync_fn
        self.post_fn = post_fn
        self.secrets = secrets or feeds.KeyringSecrets()
        self.probe_fn = probe_fn or (lambda *a, **kw: feeds.probe(*a, **kw))
        self.schedule_install_fn, self.schedule_remove_fn = schedule_install_fn, schedule_remove_fn
        self.schedule_status_fn = schedule_status_fn
        self.worker = worker or BleWorker()
        self.inbox: queue.Queue = queue.Queue()
        self.preview_slots = threading.Semaphore(2)
        self.job: str | None = None  # "push" / "info" / "sync" / "post" while the worker runs one
        self.unfinished: set[int] = set()  # pages of the current push not done yet
        self.sync_kinds: dict[int, str] = {}  # page kinds of the running sync
        self.calendar_images: dict[int, tuple[str, Image.Image]] = {}  # in memory only
        #: message board kind -> (the notes it was drawn from, drawing)
        self.board_images: dict[str, tuple[tuple, Image.Image]] = {}
        self.calendar_ok = calendar_ok_fn()
        self.feeds_dialog: FeedsDialog | None = None
        self.notes_dialog: NotesDialog | None = None
        self.settings = config.Settings()
        self.reload_settings(report=True)
        root.title("Paperhue")

        top = ttk.Frame(root, padding=(12, 10, 12, 0))
        top.pack(side="top", fill="x")
        self.device = ttk.Label(top, text="裝置狀態：尚未讀取")
        self.device.pack(side="left")
        self.info_btn = ttk.Button(top, text="讀取狀態", command=self.read_info)
        self.info_btn.pack(side="right")

        cal = ttk.Frame(root, padding=(12, 8, 12, 0))
        cal.pack(side="top", fill="x")
        self.feeds_label = ttk.Label(cal, text="")
        self.feeds_label.grid(row=0, column=0, sticky="w")
        self.last_sync = ttk.Label(cal, text="", foreground="#555")
        self.last_sync.grid(row=1, column=0, sticky="w")
        cal.columnconfigure(0, weight=1)
        buttons = ttk.Frame(cal)
        buttons.grid(row=0, column=1, rowspan=2, sticky="e")
        self.feeds_btn = ttk.Button(buttons, text="行事曆來源…", command=self.open_feeds)
        self.feeds_btn.pack(side="left")
        self.notes_btn = ttk.Button(buttons, text="留言…", command=self.open_notes)
        self.notes_btn.pack(side="left", padx=(6, 0))
        self.sync_btn = ttk.Button(buttons, text="立即同步", command=self.sync_now)
        self.sync_btn.pack(side="left", padx=(6, 0))
        self.schedule_btn = ttk.Button(buttons, text="每日排程…", command=self.open_schedule)
        if sys.platform == "win32":
            self.schedule_btn.pack(side="left", padx=(6, 0))

        opts = ttk.Frame(root, padding=(12, 6))
        opts.pack(side="top", fill="x")
        self.fit = tk.StringVar(value="cover")
        self.grain = tk.StringVar(value=next(iter(image.GRAIN)))
        grain = ttk.Combobox(opts, textvariable=self.grain, values=list(image.GRAIN), state="readonly", width=7)
        grain.bind("<<ComboboxSelected>>", lambda e: self.rerender())
        self.option_widgets = [
            ttk.Radiobutton(opts, text="填滿畫面（裁切多餘部分）", value="cover", variable=self.fit,
                            command=self.rerender),
            ttk.Radiobutton(opts, text="完整顯示（留白邊）", value="contain", variable=self.fit,
                            command=self.rerender),
            ttk.Label(opts, text="顆粒感"),
            grain,
        ]
        for i, w in enumerate(self.option_widgets):
            w.pack(side="left", padx=(0 if i == 0 else 4 if w is grain else 12, 0))
        self.grain_box = grain

        # Packed before the grid and anchored to the bottom: on a short screen
        # the previews get clipped, never the push button.
        bottom = ttk.Frame(root, padding=(12, 0, 12, 12))
        bottom.pack(side="bottom", fill="x")
        self.push_btn = ttk.Button(bottom, text="推送照片到裝置", command=self.push)
        self.push_btn.pack(side="right")
        self.summary = ttk.Label(bottom, text="照片頁：選照片後按「推送照片到裝置」。行事曆與待辦頁：按上方「立即同步」。")
        self.summary.pack(side="left")

        grid = ttk.Frame(root, padding=12)
        grid.pack(side="top", fill="both", expand=True)
        self.tiles = {slot: Tile(grid, slot, self, thumb or THUMB, self.settings.pages.get(slot, "photo"))
                      for slot in USER_SLOTS}
        for i, tile in enumerate(self.tiles.values()):
            tile.box.grid(row=i // 2, column=i % 2, padx=6, pady=6, sticky="nsew")
        grid.columnconfigure((0, 1), weight=1)
        if thumb is None:
            self.fit_to_screen()

        self.refresh_feeds()
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(100, self.poll)

    def fit_to_screen(self) -> None:
        """Shrink the previews if the window would not fit the screen's height."""
        self.root.update_idletasks()
        overhead = self.root.winfo_reqheight() - 2 * THUMB[1]
        scale = self.root.winfo_fpixels("1i") / 96
        thumb = thumb_size(self.root.winfo_screenheight(), overhead, round(RESERVED * scale))
        if thumb != THUMB:
            for tile in self.tiles.values():
                tile.resize(thumb)

    # --- state -----------------------------------------------------------------

    def reload_settings(self, report: bool = False) -> config.Settings:
        """Settings as saved now (the CLI or a scheduled run may have changed them)."""
        try:
            self.settings = config.load()
        except UlaniError as e:
            if report:
                messagebox.showerror("設定檔有誤", f"{e}\n\n先使用預設值。")
        return self.settings

    def save_settings(self) -> bool:
        try:
            config.save(self.settings)
        except (OSError, ValueError) as e:
            messagebox.showerror("無法儲存設定", str(e))
            return False
        return True

    def refresh_feeds(self) -> None:
        names = "、".join(f.name for f in self.settings.feeds)
        if not self.calendar_ok:
            text = "行事曆：這個版本缺少行事曆套件（pip install \"ulani-epaper[calendar]\"）"
        elif names:
            text = f"行事曆來源：{names}"
        else:
            text = "行事曆來源：尚未設定（按「行事曆來源…」加入 iCal 網址）"
        self.feeds_label.configure(text=text)
        self.refresh_last()
        self.update_buttons()

    def refresh_last(self) -> None:
        last = syncjob.last()
        if not last:
            self.last_sync.configure(text="上次同步：尚無紀錄")
            return
        try:
            when = f"{datetime.fromisoformat(last['time']):%m/%d %H:%M}"
        except (KeyError, ValueError):
            when = "?"
        outcome = "成功" if last.get("ok") else f"失敗（{str(last.get('message', ''))[:60]}）"
        self.last_sync.configure(text=f"上次同步：{when} {outcome}")

    def set_kind(self, slot: int, kind: str) -> None:
        tile = self.tiles[slot]
        if self.worker.busy:
            tile.combo.set(PAGE_NAMES[tile.kind])
            return
        self.reload_settings().pages[slot] = kind
        self.save_settings()
        tile.set_kind(kind)
        self.update_buttons()

    # --- actions -------------------------------------------------------------

    def rerender(self) -> None:
        if self.worker.busy:
            return
        for tile in self.tiles.values():
            tile.render()

    def frames(self) -> dict[int, bytes]:
        """Photo pages ready to push (calendar pages go through sync)."""
        return {slot: t.frame for slot, t in self.tiles.items() if t.kind == "photo" and t.frame is not None}

    def update_buttons(self) -> None:
        busy = self.worker.busy
        photos = [t for t in self.tiles.values() if t.kind == "photo"]
        pending = any(t.path and t.frame is None for t in photos)
        ready = bool(self.frames()) and not pending and not busy
        state = "disabled" if busy else "normal"
        self.push_btn.configure(state="normal" if ready else "disabled")
        self.info_btn.configure(state=state)
        for t in self.tiles.values():
            photo_state = "normal" if not busy and t.kind == "photo" else "disabled"
            t.pick.configure(state=photo_state)
            t.clear_btn.configure(state=photo_state)
            t.combo.configure(state="disabled" if busy else "readonly")
        for w in self.option_widgets:
            w.configure(state=state)
        self.grain_box.configure(state="disabled" if busy else "readonly")
        calendar_idle = self.calendar_ok and not busy
        self.feeds_btn.configure(state="normal" if calendar_idle else "disabled")
        self.sync_btn.configure(state="normal" if not busy and self.can_sync(self.settings) else "disabled")
        self.schedule_btn.configure(state=state)
        self.notes_btn.configure(state=state)
        if self.notes_dialog and self.notes_dialog.win.winfo_exists():
            self.notes_dialog.update_buttons()

    def can_sync(self, settings: config.Settings) -> bool:
        """Some page to draw, and the calendar sources it needs (message board pages need none)."""
        pages = settings.calendar_pages()
        if any(kind in CALENDAR_KINDS for kind in pages.values()):
            return bool(self.calendar_ok and settings.feeds)
        return bool(pages)

    def push(self) -> None:
        frames = self.frames()
        if not frames:
            return
        for slot, tile in self.tiles.items():
            if tile.kind == "photo":
                tile.set_progress("等待中" if slot in frames else "", 0)

        async def job(report):
            return await self.push_fn(frames, lambda event: report("progress", event))

        if self.worker.submit(job, lambda msg: self.inbox.put(("push",) + msg)):
            self.job, self.unfinished = "push", set(frames)
            self.summary.configure(text="連線並推送中…（正在顯示的那一頁會最後傳）")
            self.update_buttons()

    def sync_now(self) -> None:
        if self.worker.busy:
            return
        settings = copy.deepcopy(self.reload_settings())
        pages = settings.calendar_pages()
        if not self.can_sync(settings):
            return

        async def job(report):
            return await self.sync_fn(settings, lambda event: report("progress", event),
                                      lambda images: report("rendered", images))

        if self.worker.submit(job, lambda msg: self.inbox.put(("sync",) + msg)):
            self.job, self.unfinished, self.sync_kinds = "sync", set(pages), dict(pages)
            for slot, kind in pages.items():
                self.tiles[slot].set_progress("讀取行事曆中…" if kind in CALENDAR_KINDS else "準備留言中…", 0)
            self.summary.configure(text="讀取行事曆與待辦事項…" if set(pages.values()) & set(CALENDAR_KINDS)
                                   else "準備留言頁…")
            self.update_buttons()

    def read_info(self) -> None:
        async def job(report):
            return await self.info_fn()

        if self.worker.submit(job, lambda msg: self.inbox.put(("info",) + msg)):
            self.job = "info"
            self.device.configure(text="裝置狀態：連線中…")
            self.update_buttons()

    def open_feeds(self) -> FeedsDialog | None:
        if not self.calendar_ok or self.worker.busy:
            return None
        if self.feeds_dialog and self.feeds_dialog.win.winfo_exists():
            self.feeds_dialog.win.lift()
        else:
            self.feeds_dialog = FeedsDialog(self)
        return self.feeds_dialog

    def open_notes(self) -> NotesDialog:
        if self.notes_dialog and self.notes_dialog.win.winfo_exists():
            self.notes_dialog.win.lift()
            self.notes_dialog.refresh()
        else:
            self.notes_dialog = NotesDialog(self)
        return self.notes_dialog

    def board_drawing(self, kind: str) -> Image.Image | None:
        """The message board page ``kind`` drawn from the saved notes (no
        network, so it shows at once); None if the notes file is unreadable."""
        try:
            current = tuple(note_store.load())
        except UlaniError:
            return None
        cached = self.board_images.get(kind)
        if cached and cached[0] == current:
            return cached[1]
        drawing = layouts.BOARD_RENDERERS[kind](list(current), LOCAL)
        self.board_images[kind] = (current, drawing)
        return drawing

    def refresh_boards(self) -> None:
        """Redraw the message board tiles after the notes changed."""
        for tile in self.tiles.values():
            if tile.kind in BOARD_KINDS:
                tile.show_content()

    def say_post(self, text: str, error: bool = False) -> None:
        """Progress of a message board push: the status line, and the dialog if it is open."""
        self.summary.configure(text=text)
        if self.notes_dialog and self.notes_dialog.win.winfo_exists():
            self.notes_dialog.say(text, error)

    def post_board(self, show: str) -> bool:
        """Push the message board pages on the worker (see sync.post); ``show``
        "auto" also switches the display to them, "none" does not."""
        settings = copy.deepcopy(self.reload_settings())
        pages = settings.board_pages()
        if not pages or self.worker.busy:
            return False

        async def job(report):
            return await self.post_fn(settings, show, lambda event: report("progress", event),
                                      lambda images: report("rendered", images))

        if not self.worker.submit(job, lambda msg: self.inbox.put(("post",) + msg)):
            return False
        self.job, self.unfinished, self.sync_kinds = "post", set(pages), dict(pages)
        for slot in pages:
            self.tiles[slot].set_progress("等待傳送", 0)
        self.say_post("連線並推送留言頁中…（正在顯示的那一頁會最後傳）")
        self.update_buttons()
        return True

    def check_feed_async(self, form: "FeedForm", url: str, user: str, password: str) -> None:
        """Download and read an address on a thread; the answer goes to ``form`` via the inbox."""
        def work() -> None:
            try:
                outcome: tuple = ("done", self.probe_fn(url, user, password))
            except Exception as e:  # shown in the form
                outcome = ("error", e)
            self.inbox.put(("feed-check", form) + outcome)

        threading.Thread(target=work, name="feed-check", daemon=True).start()

    def open_schedule(self) -> None:
        try:
            current = self.schedule_status_fn()
        except Exception as e:
            messagebox.showerror("每日排程", str(e))
            return
        win = tk.Toplevel(self.root)
        win.title("每日自動同步")
        win.transient(self.root)
        frm = ttk.Frame(win, padding=12)
        frm.pack(fill="both", expand=True)
        ttk.Label(frm, text="每天在這些時間讀取行事曆並更新裝置（24 小時制，多個時間用逗號分隔）：",
                  wraplength=440).pack(anchor="w")
        entry = ttk.Entry(frm, width=40)
        entry.insert(0, ", ".join(current["times"] if current else self.reload_settings().times))
        entry.pack(anchor="w", pady=6)

        def describe_state(st: dict | None) -> str:
            return f"目前：已啟用，每天 {', '.join(st['times'])}" if st else "目前：未啟用"

        state = ttk.Label(frm, text=describe_state(current))
        state.pack(anchor="w")
        ttk.Label(frm, text="電腦需要開機並登入 Windows；關機或睡眠時錯過的時間，會在下次開機後補做。",
                  wraplength=440, foreground="#555").pack(anchor="w", pady=(6, 0))
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=(10, 0))

        def refresh_state() -> None:
            try:
                state.configure(text=describe_state(self.schedule_status_fn()))
            except Exception:
                pass

        ttk.Button(row, text="啟用／更新排程",
                   command=lambda: self.apply_schedule(entry.get()) and refresh_state()).pack(side="left")
        ttk.Button(row, text="停用排程",
                   command=lambda: (self.remove_schedule(), refresh_state())).pack(side="left", padx=6)
        ttk.Button(row, text="關閉", command=win.destroy).pack(side="right")

    def apply_schedule(self, text: str) -> bool:
        try:
            times = parse_times(text)
        except ValueError as e:
            messagebox.showerror("時間格式不正確", str(e))
            return False
        self.reload_settings().times = times
        try:
            config.save(self.settings)
            self.schedule_install_fn(times)
        except Exception as e:
            messagebox.showerror("無法建立排程", str(e))
            return False
        return True

    def remove_schedule(self) -> None:
        try:
            self.schedule_remove_fn()
        except Exception as e:
            messagebox.showerror("無法停用排程", str(e))

    # --- messages from worker threads -------------------------------------------

    def poll(self) -> None:
        try:
            while True:
                try:
                    self.handle(self.inbox.get_nowait())
                except queue.Empty:
                    break
                except Exception:  # one bad message must never stop the loop for good
                    import traceback

                    traceback.print_exc()
        finally:
            self.root.after(100, self.poll)

    def handle(self, msg: tuple) -> None:
        kind = msg[0]
        if kind == "preview":
            _, slot, gen, frame, thumb = msg
            self.tiles[slot].show_preview(gen, frame, thumb)
        elif kind == "preview-error":
            _, slot, gen, error, name = msg
            self.tiles[slot].show_preview_error(gen, error, name)
        elif kind == "feed-check":
            _, form, what, value = msg
            form.checked(what, value)
        elif kind in ("push", "info", "sync", "post"):
            if msg[1] in ("done", "error"):
                self.job = None
            {"push": self.handle_push, "info": self.handle_info, "sync": self.handle_sync,
             "post": self.handle_post}[kind](msg[1], msg[2])
        self.update_buttons()

    def _progress(self, event: PushEvent, unchanged: str) -> None:
        slot, text, percent = describe(event)
        if event.phase == "unchanged":
            text = unchanged
        self.tiles[slot].set_progress(text, percent)
        if event.phase in ("done", "unchanged", "refreshing"):
            self.unfinished.discard(slot)

    def _mark_unfinished(self) -> None:
        for slot in sorted(self.unfinished):
            tile = self.tiles[slot]
            tile.set_progress("未完成", tile.bar.cget("value"))
        self.unfinished = set()

    def handle_push(self, what: str, value: Any) -> None:
        if what == "progress":
            self._progress(value, "已是這張照片，略過")
        elif what == "done":
            changed = sum(r is UploadResult.OK for r in value.values())
            self.summary.configure(text=f"完成：{changed} 頁已更新，{len(value) - changed} 頁原本就相同。")
            self.device.configure(text="裝置狀態：剛完成推送（按「讀取狀態」可更新）")
            self.unfinished = set()
        elif what == "error":
            self.summary.configure(text="推送失敗，請看錯誤訊息後再試一次。")
            self._mark_unfinished()
            messagebox.showerror("推送失敗", friendly(value))

    def handle_sync(self, what: str, value: Any) -> None:
        if what == "rendered":
            for slot, drawing in value.items():
                kind = self.sync_kinds.get(slot, "")
                self.calendar_images[slot] = (kind, drawing)
                if self.tiles[slot].kind == kind:
                    self.tiles[slot].show_calendar(drawing)
                self.tiles[slot].set_progress("等待傳送", 0)
            self.summary.configure(text="行事曆已讀取，連線並推送中…（正在顯示的那一頁會最後傳）")
        elif what == "progress":
            self._progress(value, "內容沒有變化，略過")
        elif what == "done":
            message = syncjob.describe(value)
            syncjob.record(True, message)
            self.summary.configure(text=f"同步完成：{message}")
            self.device.configure(text="裝置狀態：剛完成同步（按「讀取狀態」可更新）")
            self.unfinished = set()
            self.refresh_last()
        elif what == "error":
            syncjob.record(False, str(value) or type(value).__name__)
            self.summary.configure(text="同步失敗，請看錯誤訊息後再試一次。")
            self._mark_unfinished()
            self.refresh_last()
            messagebox.showerror("同步失敗", friendly(value))

    def handle_post(self, what: str, value: Any) -> None:
        if what == "rendered":
            self.say_post("留言頁已畫好，連線並推送中…（正在顯示的那一頁會最後傳）")
        elif what == "progress":
            self._progress(value, "內容沒有變化，略過")
            slot, text, _ = describe(value)
            self.say_post(f"第 {slot} 頁：{text}")
        elif what == "done":
            self.say_post(post_summary(value))
            self.device.configure(text="裝置狀態：剛完成推送留言（按「讀取狀態」可更新）")
            self.unfinished = set()
        elif what == "error":
            self.say_post("留言已存在這台電腦，但沒有送到裝置；下次同步時會一併更新。", error=True)
            self._mark_unfinished()
            messagebox.showerror("留言推送失敗", friendly(value))

    def handle_info(self, what: str, value: Any) -> None:
        if what == "done":
            battery = value["battery"]
            level = "充電中" if battery.charging else f"{battery.level}/5"
            self.device.configure(text=f"裝置狀態：電量 {level}，目前顯示第 {value['shown']} 頁")
        elif what == "error":
            self.device.configure(text="裝置狀態：連不上")
            messagebox.showerror("讀取狀態失敗", friendly(value))

    def load_dropped(self, paths: list[str]) -> None:
        """Photos dropped onto the exe: one per photo page; if there are more
        photos than photo pages, offer to turn the first calendar pages into
        photo pages (the v0.2 behaviour was four photos on pages 1-4)."""
        paths = paths[: len(USER_SLOTS)]
        photo_slots = [s for s, t in self.tiles.items() if t.kind == "photo"]
        missing = len(paths) - len(photo_slots)
        if missing > 0:
            convert = [s for s, t in self.tiles.items() if t.kind != "photo"][:missing]
            names = "、".join(f"第 {s} 頁（{PAGE_NAMES[self.tiles[s].kind]}）" for s in convert)
            if messagebox.askyesno("照片比照片頁多", f"拖進來 {len(paths)} 張照片，但只有 {len(photo_slots)} 頁"
                                                    f"設為照片。\n要把{names}改成照片嗎？"):
                for slot in convert:
                    self.set_kind(slot, "photo")
                photo_slots = sorted(photo_slots + convert)
        for slot, path in zip(photo_slots, paths):
            self.tiles[slot].set_path(path)
        if len(paths) > len(photo_slots):
            self.summary.configure(text=f"只載入了 {len(photo_slots)} 張照片：其他頁面設為行事曆。")

    def close(self) -> None:
        if self.job in ("push", "sync", "post") and not messagebox.askyesno(
                "仍在傳送", "還在傳送到裝置，現在關閉會中斷傳送。確定要關閉嗎？"):
            return
        self.worker.close()
        self.root.destroy()


class NotesDialog:
    """「留言」: write a note and post it to the message board pages; the notes so far, delete, clear."""

    def __init__(self, app: App) -> None:
        self.app = app
        self.win = win = tk.Toplevel(app.root)
        win.title("留言")
        win.transient(app.root)
        frm = ttk.Frame(win, padding=12)
        frm.pack(fill="both", expand=True)
        self.help = ttk.Label(frm, text="", wraplength=460, justify="left", foreground="#c00")
        self.help.pack(anchor="w")
        ttk.Label(frm, text=f"留言內容（最多 {note_store.MAX_TEXT} 字、{note_store.MAX_LINES} 行）：").pack(anchor="w")
        self.text = tk.Text(frm, width=46, height=5, wrap="char", undo=True)
        self.text.pack(fill="x", pady=(4, 0))
        self.text.bind("<<Modified>>", self._modified)
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=(6, 0))
        ttk.Label(row, text="顏色").pack(side="left")
        self.colour = tk.StringVar(value="yellow")
        self.colour_buttons = [ttk.Radiobutton(row, text=label, value=key, variable=self.colour)
                               for key, label in NOTE_COLOUR_NAMES.items()]
        for b in self.colour_buttons:
            b.pack(side="left", padx=(8, 0))
        self.counter = ttk.Label(row, text="", foreground="#555")
        self.counter.pack(side="right")
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=(8, 0))
        self.post_btn = ttk.Button(row, text="張貼並顯示", command=self.post)
        self.post_btn.pack(side="left")
        self.status = ttk.Label(frm, text="張貼後會更新留言頁，並讓裝置切換到留言頁。", wraplength=460,
                                justify="left", foreground="#555")
        self.status.pack(anchor="w", pady=(6, 0))
        ttk.Label(frm, text="已張貼的留言（最新的在最上面）：").pack(anchor="w", pady=(10, 0))
        self.tree = ttk.Treeview(frm, columns=("time", "text"), show="headings", height=6, selectmode="browse")
        for col, title, width in (("time", "時間", 100), ("text", "內容", 360)):
            self.tree.heading(col, text=title)
            self.tree.column(col, width=width, anchor="w")
        self.tree.pack(fill="both", expand=True, pady=(4, 8))
        row = ttk.Frame(frm)
        row.pack(fill="x")
        self.remove_btn = ttk.Button(row, text="刪除", command=self.remove)
        self.remove_btn.pack(side="left")
        self.clear_btn = ttk.Button(row, text="全部清除", command=self.clear)
        self.clear_btn.pack(side="left", padx=6)
        ttk.Button(row, text="關閉", command=win.destroy).pack(side="right")
        self.update_counter()
        self.refresh()
        self.text.focus_set()

    def say(self, text: str, error: bool = False) -> None:
        self.status.configure(text=text, foreground="#c00" if error else "#555")

    def written(self) -> str:
        return self.text.get("1.0", "end-1c")

    def _modified(self, _event=None) -> None:
        self.text.edit_modified(False)  # re-arm <<Modified>> for the next change
        self.update_counter()

    def update_counter(self) -> None:
        count = len(note_store.normalize(self.written()))
        self.counter.configure(text=f"{count} / {note_store.MAX_TEXT}",
                               foreground="#c00" if count > note_store.MAX_TEXT else "#555")

    def refresh(self) -> None:
        """The saved notes, newest first."""
        self.tree.delete(*self.tree.get_children())
        try:
            notes = note_store.load()
        except UlaniError as e:
            self.say(str(e), error=True)
            notes = []
        for n in notes:
            lines = n.text.split("\n")
            self.tree.insert("", "end", iid=n.id,
                             values=(note_store.when(n), lines[0] + (" …" if len(lines) > 1 else "")))
        self.update_buttons()

    def update_buttons(self) -> None:
        busy = self.app.worker.busy
        boards = bool(self.app.settings.board_pages())
        self.help.configure(text="" if boards else NO_BOARD_HELP)
        self.post_btn.configure(state="normal" if boards and not busy else "disabled")
        has_notes = bool(self.tree.get_children())
        for b in (self.remove_btn, self.clear_btn):
            b.configure(state="normal" if has_notes and not busy else "disabled")

    def _changed(self, show: str) -> None:
        """The notes were saved: redraw the list and the tiles, then update the device."""
        self.refresh()
        self.app.refresh_boards()
        self.app.post_board(show)

    def post(self) -> None:
        if self.app.worker.busy or not self.app.reload_settings().board_pages():
            return
        try:
            note_store.add(self.written(), self.colour.get())
        except ValueError as e:  # empty, too long, too many lines
            return self.say(str(e), error=True)
        except (UlaniError, OSError) as e:
            return self.say(f"無法儲存留言：{e}", error=True)
        self.text.delete("1.0", "end")
        self.update_counter()
        self._changed("auto")

    def remove(self) -> None:
        chosen = self.tree.selection()
        if self.app.worker.busy:
            return
        if not chosen:
            return self.say("請先在清單中點選要刪除的留言。", error=True)
        try:
            note_store.remove(chosen[0])
        except (UlaniError, OSError) as e:
            return self.say(f"無法刪除：{e}", error=True)
        self.say("已刪除這則留言。")
        self._changed("none")

    def clear(self) -> None:
        count = len(self.tree.get_children())
        if self.app.worker.busy or not count:
            return
        if not messagebox.askyesno("全部清除", f"要刪除全部 {count} 則留言嗎？刪除後無法復原。", parent=self.win):
            return
        try:
            note_store.clear()
        except (UlaniError, OSError) as e:
            return self.say(f"無法清除：{e}", error=True)
        self.say("已清除全部留言。")
        self._changed("none")


class FeedsDialog:
    """「行事曆來源」: the calendar sources (name, colour, host); add, edit, remove."""

    def __init__(self, app: App) -> None:
        self.app = app
        self.win = win = tk.Toplevel(app.root)
        win.title("行事曆來源")
        win.transient(app.root)
        frm = ttk.Frame(win, padding=12)
        frm.pack(fill="both", expand=True)
        ttk.Label(frm, text=FEEDS_HELP, wraplength=500, justify="left").pack(anchor="w")
        self.tree = ttk.Treeview(frm, columns=("name", "color", "host"), show="headings", height=6,
                                 selectmode="browse")
        for col, title, width in (("name", "名稱", 140), ("color", "顏色", 60), ("host", "來源", 280)):
            self.tree.heading(col, text=title)
            self.tree.column(col, width=width, anchor="w")
        self.tree.pack(fill="both", expand=True, pady=8)
        row = ttk.Frame(frm)
        row.pack(fill="x")
        ttk.Button(row, text="新增…", command=self.add).pack(side="left")
        ttk.Button(row, text="編輯…", command=self.edit).pack(side="left", padx=6)
        ttk.Button(row, text="刪除", command=self.remove).pack(side="left")
        ttk.Button(row, text="關閉", command=win.destroy).pack(side="right")
        self.refresh()

    def secret(self, feed_id: str) -> dict | None:
        try:
            return self.app.secrets.get(feed_id)
        except Exception:  # credential store unavailable
            return None

    def refresh(self) -> None:
        settings = self.app.reload_settings()
        self.tree.delete(*self.tree.get_children())
        for f in settings.feeds:
            info = self.secret(f.id)
            host = feeds.where(info["url"]) if info and info.get("url") else "（網址遺失：請刪除後重新加入）"
            self.tree.insert("", "end", iid=f.id, values=(f.name, COLOUR_NAMES.get(f.color, f.color), host))
        self.app.refresh_feeds()

    def selected(self) -> config.Feed | None:
        chosen = self.tree.selection()
        return self.app.settings.feed(chosen[0]) if chosen else None

    def add(self) -> FeedForm:
        return FeedForm(self, None)

    def edit(self) -> FeedForm | None:
        feed = self.selected()
        return FeedForm(self, feed) if feed else None

    def remove(self) -> None:
        feed = self.selected()
        if not feed or not messagebox.askyesno("刪除來源", f"要刪除「{feed.name}」嗎？\n它的網址也會從這台電腦刪除。"):
            return
        settings = self.app.reload_settings()
        current = settings.feed(feed.id)
        if current:
            try:
                feeds.remove_feed(settings, current, self.app.secrets)
            except Exception as e:
                messagebox.showerror("刪除失敗", str(e))
                return
            self.app.save_settings()
        self.refresh()


class FeedForm:
    """Add or edit one source. A new address is checked by downloading it once before it is saved."""

    def __init__(self, dialog: FeedsDialog, feed: config.Feed | None) -> None:
        self.dialog, self.app, self.feed = dialog, dialog.app, feed
        self.old = dialog.secret(feed.id) if feed else None
        self.win = win = tk.Toplevel(dialog.win)
        win.title("新增行事曆來源" if feed is None else f"編輯「{feed.name}」")
        win.transient(dialog.win)
        frm = ttk.Frame(win, padding=12)
        frm.pack(fill="both", expand=True)
        self.name = tk.StringVar(value=feed.name if feed else "")
        self.url = tk.StringVar()
        self.colour = tk.StringVar(value=COLOUR_NAMES.get(feed.color if feed else "", "自動"))
        self.user = tk.StringVar(value=(self.old or {}).get("user", ""))
        self.password = tk.StringVar()
        fields = [
            ("名稱（顯示在頁面上）", ttk.Entry(frm, textvariable=self.name, width=42)),
            ("iCal 網址" + ("（留空＝不變）" if feed else ""), ttk.Entry(frm, textvariable=self.url, width=42, show="•")),
            ("顏色", ttk.Combobox(frm, textvariable=self.colour, values=list(COLOUR_NAMES.values()),
                                 state="readonly", width=8)),
            ("帳號（需要登入時才填）", ttk.Entry(frm, textvariable=self.user, width=42)),
            ("密碼 / App 密碼" + ("（留空＝不變）" if feed else ""),
             ttk.Entry(frm, textvariable=self.password, width=42, show="•")),
        ]
        for i, (label, widget) in enumerate(fields):
            ttk.Label(frm, text=label).grid(row=i, column=0, sticky="w", pady=3, padx=(0, 8))
            widget.grid(row=i, column=1, sticky="w", pady=3)
        self.status = ttk.Label(frm, text="網址會隱藏顯示，只存在這台電腦的認證管理員。", wraplength=440,
                                foreground="#555")
        self.status.grid(row=len(fields), column=0, columnspan=2, sticky="w", pady=(8, 0))
        row = ttk.Frame(frm)
        row.grid(row=len(fields) + 1, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        self.save_btn = ttk.Button(row, text="檢查並儲存", command=self.save)
        self.save_btn.pack(side="left")
        ttk.Button(row, text="取消", command=win.destroy).pack(side="right")
        self.pending: tuple | None = None

    def colour_value(self) -> str:
        return next((key for key, label in COLOUR_NAMES.items() if label == self.colour.get()), "")

    def say(self, text: str, error: bool = False) -> None:
        self.status.configure(text=text, foreground="#c00" if error else "#555")

    def save(self) -> None:
        name, url = self.name.get().strip(), self.url.get().strip()
        user, password = self.user.get().strip(), self.password.get()
        if not name:
            return self.say("請輸入名稱，例如「個人」或「學校」。", error=True)
        if not url and not self.old:
            return self.say("請貼上 iCal 網址。", error=True)
        old = self.old or {}
        if self.feed and not url and not password and user == old.get("user", ""):
            return self.store(name, None, None, None)  # only the name or colour changed
        try:
            url = feeds.normalize_url(url or old.get("url", ""))
        except feeds.FeedError as e:
            return self.say(str(e), error=True)
        old_user, old_password = feeds.login_for(old, url)  # another host: the old password is not reused
        if not password and user == old_user:
            password = old_password
        self.pending = (name, url, user, password)
        self.save_btn.configure(state="disabled")
        self.say(f"正在讀取 {feeds.where(url)} …")
        self.app.check_feed_async(self, url, user, password)

    def checked(self, what: str, value: Any) -> None:
        if not self.win.winfo_exists():
            return
        self.save_btn.configure(state="normal")
        if what == "error":
            return self.say(f"無法使用這個網址：{value}", error=True)
        name, url, user, password = self.pending
        if self.store(name, url, user, password):
            self.app.summary.configure(
                text=f"已儲存「{name}」：近期 {len(value.events)} 個行程、{len(value.tasks)} 項待辦。")

    def store(self, name: str, url: str | None, user: str | None, password: str | None) -> bool:
        settings = self.app.reload_settings()
        current = settings.feed(self.feed.id) if self.feed else None
        try:
            if current:
                current.name, current.color = name, self.colour_value()
                settings.validate()
                if url is not None:
                    self.app.secrets.set(current.id, url, user or "", password or "")
            else:
                feeds.new_feed(settings, name, url, self.colour_value(), user or "", password or "",
                               self.app.secrets)
        except (ValueError, UlaniError) as e:
            self.say(str(e), error=True)
            return False
        if not self.app.save_settings():
            return False
        self.dialog.refresh()
        self.win.destroy()
        return True


def _enable_dpi_awareness() -> None:
    if sys.platform == "win32":
        try:
            import ctypes

            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass


def main(argv: list[str] | None = None) -> None:
    """Start the app. Image paths given on the command line (or dropped onto
    the .exe in Explorer) are loaded into the photo pages."""
    paths = (sys.argv[1:] if argv is None else argv)[: len(USER_SLOTS)]
    Image.MAX_IMAGE_PIXELS = image.MAX_PHOTO_PIXELS  # the user's own photos (200 MP phones)
    _enable_dpi_awareness()
    root = tk.Tk()
    app = App(root)
    if paths:
        app.load_dropped(paths)
    root.mainloop()


if __name__ == "__main__":
    main()
