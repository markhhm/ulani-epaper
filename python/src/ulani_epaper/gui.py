"""Paperhue, the desktop app: photos, calendar / to-do pages and a message board for the device (``paperhue``).

tkinter only (ships with Python). Bluetooth runs on a BleWorker thread; the
Tk thread only reads a queue. Each of the four pages shows a photo, a month
calendar, a week agenda, a to-do list, the message board (sticky notes) or
the newest note in large type (saved in the settings). Calendar pages come
from the user's own iCal addresses ("feeds"); their data is fetched, drawn
and pushed in memory only. The notes are the owner's own words, kept in
notes.json (notes.py) and drawn locally, without any network.
Every text comes from strings.py, in Traditional Chinese or English: the button in the top
bar switches the language of the whole window, and of the open dialogs, at once.
"""

from __future__ import annotations

import base64
import copy
import os
import queue
import sys
import threading
import tkinter as tk
from datetime import datetime
from importlib import resources
from tkinter import filedialog, messagebox, ttk
from typing import Any, Awaitable, Callable

from bleak.exc import BleakError
from PIL import Image, ImageTk, UnidentifiedImageError

from . import config, feeds, image, layouts, push, schedule, strings, sync, syncjob
from . import notes as note_store
from .agenda import LOCAL
from .client import DeviceBusy, NoReply, PushEvent, UploadFailed, UploadResult, connect
from .config import BOARD_KINDS, CALENDAR_KINDS, CARD_KINDS, PAGE_KINDS
from .gui_model import (BleWorker, crop_or_default, describe, move_crop, nudge_crop, parse_times, photo_to_view,
                        resize_crop, view_to_photo, zoom_crop, zoom_level)
from .protocol import USER_SLOTS, UlaniError
from .strings import later, page_name, pages, t

#: Largest preview size (5:3, like the panel).
THUMB = (384, 230)
#: Smallest preview height used on short screens.
MIN_THUMB_HEIGHT = 96
#: Vertical pixels (at 96 dpi) the OS takes outside the window: taskbar + title bar.
RESERVED = 80
#: Window height (at 96 dpi) not taken by the two rows of previews.
OVERHEAD = 520
IMAGE_EXTENSIONS = "*.jpg *.jpeg *.png *.bmp *.gif *.webp *.tif *.tiff"
#: feed colour -> text key of its name in the colour picker
FEED_COLOUR_KEYS = {"": "feed_colour_auto", "red": "feed_colour_red", "orange": "feed_colour_orange",
                    "yellow": "feed_colour_yellow", "green": "feed_colour_green", "blue": "feed_colour_blue",
                    "black": "feed_colour_black"}
#: note colour -> text key of its name in the notes dialog, in the order shown
NOTE_COLOUR_KEYS = {"yellow": "note_yellow", "orange": "note_orange", "green": "note_green", "blue": "note_blue",
                    "red": "note_red"}
#: image.GRAIN's names (the settings of the CLI too) -> text key of their names in the grain picker
GRAIN_KEYS = {"標準": "grain_standard", "柔和": "grain_soft", "更柔和": "grain_softer", "最平滑": "grain_smoothest"}
#: The app icon, package data in ulani_epaper/assets/ (made by shared/brand/make_icons.py).
ICON_ICO = "paperhue.ico"
ICON_PNGS = ("paperhue-256.png", "paperhue-32.png")

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


def icon_asset(name: str):
    """An icon in the package's assets/ folder, as an importlib.resources Traversable.

    Found the same way from a source checkout, an installed wheel and the
    one-file Paperhue.exe.
    """
    return resources.files(__package__) / "assets" / name


def exact_windows_icons(window: tk.Misc, ico: str) -> dict[int, int]:
    """Windows: show the .ico's own image at the exact size the title bar and the taskbar use.

    Tk hands Windows the .ico's 32 px image for every size, and Windows
    rescales it, which looks soft at 125 % or 150 % display scaling. This
    loads the image the screen asks for (24 px, 48 px, ...) and gives it to
    the window with WM_SETICON whenever Tk shows the window, as Tk only then
    creates the window's frame. Returns the icon handles by WM_SETICON type;
    empty if Windows could not load them, and the window keeps Tk's icon.
    """
    import ctypes

    user32 = ctypes.WinDLL("user32")  # its own handle, so these prototypes stay local
    user32.LoadImageW.restype = ctypes.c_void_p
    user32.LoadImageW.argtypes = (ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint, ctypes.c_int, ctypes.c_int,
                                  ctypes.c_uint)
    user32.SendMessageW.argtypes = (ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_void_p)
    icons = {}
    for kind, metric in ((0, 49), (1, 11)):  # ICON_SMALL: SM_CXSMICON, ICON_BIG: SM_CXICON
        side = user32.GetSystemMetrics(metric)
        handle = user32.LoadImageW(None, ico, 1, side, side, 0x10)  # IMAGE_ICON, LR_LOADFROMFILE
        if not handle:
            return {}
        icons[kind] = handle

    def show(event: tk.Event | None = None) -> None:
        if event is None or event.widget is window:
            frame = int(window.wm_frame(), 16)
            for kind, handle in icons.items():
                user32.SendMessageW(frame, 0x0080, kind, handle)  # WM_SETICON

    window.bind("<Map>", show, add="+")
    if window.winfo_ismapped():
        show()
    return icons


def set_window_icon(root: tk.Misc, platform: str = sys.platform) -> bool:
    """Give the window, and every window opened after it, the Paperhue icon.

    Windows gets the .ico, which holds every size the title bar and the
    taskbar ask for (see exact_windows_icons); elsewhere Tk takes PNGs (it
    copies them, so they need not be kept). A missing icon is no reason to
    fail to start: errors only make this return False.
    """
    try:
        if platform == "win32":
            with resources.as_file(icon_asset(ICON_ICO)) as ico:  # both read the file right away
                root.iconbitmap(default=str(ico))
                exact_windows_icons(root, str(ico))
        else:
            photos = [tk.PhotoImage(master=root, data=base64.b64encode(icon_asset(name).read_bytes()).decode())
                      for name in ICON_PNGS]
            root.iconphoto(True, *photos)
    except (OSError, tk.TclError):
        return False
    return True


def friendly(error: BaseException) -> str:
    """A short explanation in the interface language, followed by the technical message."""
    text = str(error) or type(error).__name__
    if isinstance(error, feeds.NoFeeds):
        hint = "hint_no_feeds"
    elif isinstance(error, feeds.FeedError):
        hint = "hint_feed_error"
    elif "Insufficient Authentication" in text or "Insufficient Encryption" in text:
        hint = "hint_not_paired"
    elif isinstance(error, (DeviceBusy, NoReply)):
        hint = "hint_no_response"
    elif isinstance(error, UploadFailed):
        hint = "hint_bad_data"
    elif "no e-paper device found" in text or "could not connect" in text:
        hint = "hint_not_found"
    elif isinstance(error, (BleakError, OSError)):
        hint = "hint_link_lost"
    else:
        return text
    return f"{t(hint)}\n\n{text}"


def post_summary(report: sync.SyncReport) -> str:
    """The status line after the message board pages were pushed."""
    message = syncjob.describe(report)
    return t("post_done_shown", message=message, show=report.show) if report.show else t("post_done", message=message)


def preview_error_text(name: str, error: BaseException) -> str:
    if isinstance(error, image.PhotoTooLarge):
        return t("photo_too_large")
    if isinstance(error, UnidentifiedImageError):
        why = "why_unsupported"
    elif isinstance(error, OSError):
        why = "why_damaged"
    else:
        why = "why_other"
    return t("preview_error", name=name, why=t(why))


class Labels:
    """The texts that follow the language. A widget's text is kept as a function that makes it, so
    ``relabel`` can draw every one again when the language changes, whatever state it is in.
    Everything that sets such a text goes through ``put``: a plain ``configure(text=...)`` would
    bring the old text back at the next switch.
    """

    def __init__(self) -> None:
        self.items: dict[tuple[str, str], tuple[tk.Misc, Callable[[], Any], Callable[[Any], Any]]] = {}

    def put(self, widget: tk.Misc, source: str | Callable[[], Any] = "", option: str = "text",
            apply: Callable[[Any], Any] | None = None, **fmt: Any) -> tk.Misc:
        """Show ``source`` in ``widget``: a text key (with its ``fmt``), a function that makes the
        text, or "" for none. ``option`` is the widget option it is shown in (and the name of this
        entry); ``apply`` sets it some other way (Misc.title, a Treeview heading, ...)."""
        make = later(source, **fmt) if isinstance(source, str) and source else source or (lambda: "")
        apply = apply or (lambda value: widget.configure(**{option: value}))
        apply(make())
        self.items[(str(widget), option)] = (widget, make, apply)
        return widget

    def put_text(self, widget: tk.Misc, text: str, option: str = "text") -> tk.Misc:
        """A text that is the same in both languages (a file name)."""
        return self.put(widget, lambda: text, option)

    def relabel(self) -> None:
        for key, (widget, make, apply) in list(self.items.items()):
            try:
                if widget.winfo_exists():
                    apply(make())
                    continue
            except tk.TclError:  # the window is gone
                pass
            del self.items[key]


class Tile:
    """One page: what it shows, the chosen photo or the last calendar drawing,
    preview widget, progress."""

    def __init__(self, parent: tk.Widget, slot: int, app: "App", thumb: tuple[int, int], kind: str) -> None:
        self.slot, self.app, self.kind = slot, app, kind
        self.path: str | None = None
        self.frame: bytes | None = None  # the encoded photo (photo pages only)
        self.generation = 0
        self.photo: ImageTk.PhotoImage | None = None
        self.crop: image.Crop | None = None  # the part of the photo shown in Fill (None: the centre)
        self.dialog: CropDialog | None = None

        self.labels = app.labels
        self.box = ttk.LabelFrame(parent, padding=8)
        self.labels.put(self.box, "page_title", n=slot)
        top = ttk.Frame(self.box)
        top.grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 6))
        self.labels.put(ttk.Label(top), "show_label").pack(side="left")
        self.combo = ttk.Combobox(top, state="readonly", width=12)
        self.labels.put(self.combo, lambda: [page_name(k) for k in PAGE_KINDS], "values")
        self.labels.put(self.combo, lambda: page_name(self.kind), "selection", apply=self.combo.set)
        self.combo.pack(side="left", padx=(6, 0))
        self.combo.bind("<<ComboboxSelected>>", self._kind_chosen)
        self.canvas = tk.Label(self.box, bg="#e8e8e8", fg="#666", compound="center", justify="center")
        self.canvas.grid(row=1, column=0, columnspan=3)  # centred, never stretched
        self.canvas.bind("<Button-1>", lambda e: self.clicked())
        self.canvas.bind("<Double-Button-1>", lambda e: self.double_clicked())
        self.name = ttk.Label(self.box, width=40)
        self.name.grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 2))
        buttons = ttk.Frame(self.box)
        buttons.grid(row=3, column=0, columnspan=2, sticky="w")
        self.pick = ttk.Button(buttons, command=self.choose)
        self.labels.put(self.pick, "choose_photo").pack(side="left")
        self.clear_btn = ttk.Button(buttons, command=self.clear)
        self.labels.put(self.clear_btn, "clear").pack(side="left", padx=6)
        self.adjust_btn = ttk.Button(buttons, command=self.adjust_crop, state="disabled")
        self.labels.put(self.adjust_btn, "adjust_btn").pack(side="left")
        self.bar = ttk.Progressbar(self.box, maximum=100, length=100)
        self.bar.grid(row=3, column=2, sticky="e")
        self.status = ttk.Label(self.box, foreground="#555")
        self.status.grid(row=4, column=0, columnspan=3, sticky="w", pady=(4, 0))
        self.resize(thumb)

    def _kind_chosen(self, _event=None) -> None:
        kind = PAGE_KINDS[self.combo.current()]  # the names are in PAGE_KINDS order, in either language
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
        if self.dialog:
            self.dialog.close()
        self.combo.set(page_name(kind))
        self.set_progress("", 0)
        self.show_content()

    def clicked(self) -> None:
        if self.kind in BOARD_KINDS:
            self.app.open_notes()
        elif not self.path:  # with a photo, a click is the start of a double click: the buttons choose or adjust
            self.choose()

    def double_clicked(self) -> None:
        if self.path:
            self.adjust_crop()

    def show_content(self) -> None:
        """Show the photo preview, the latest calendar drawing, or (message
        board pages) the drawing from the saved notes."""
        kind = self.kind
        if kind == "photo":
            self.labels.put_text(self.name, os.path.basename(self.path) if self.path else "")
            if self.path:
                self.render()
            else:
                self.show_text("no_photo")
            return
        self.generation += 1  # drop a photo preview still being computed
        self.frame = None
        if kind in BOARD_KINDS:
            self.labels.put(self.name, lambda: t("board_tile_name", kind=page_name(kind)))
            drawing = self.app.board_drawing(kind)
            if drawing is None:
                self.show_text("notes_unreadable")
            else:
                self.show_calendar(drawing)
            return
        if kind in CARD_KINDS:  # a sync never draws a card page: it holds what 'ulani card push' sent
            self.labels.put(self.name, lambda: t("card_tile_name", kind=page_name(kind)))
            self.show_text(lambda: t("card_tile", kind=page_name(kind)))
            return
        self.labels.put(self.name, lambda: t("calendar_tile_name", kind=page_name(kind)))
        drawn = self.app.calendar_images.get(self.slot)
        if drawn and drawn[0] == kind:
            self.show_calendar(drawn[1])
        else:
            self.show_text(lambda: t("press_sync", kind=page_name(kind)))

    def show_text(self, source: str | Callable[[], str]) -> None:
        """The blank preview with a text on it."""
        self.canvas.configure(image=self.blank)
        self.labels.put(self.canvas, source)

    def choose(self) -> None:
        if self.app.worker.busy or self.kind != "photo":
            return
        path = filedialog.askopenfilename(
            title=t("choose_photo_title", n=self.slot),
            filetypes=[(t("filetype_images"), IMAGE_EXTENSIONS), (t("filetype_all"), "*.*")])
        if path:
            self.set_path(path)

    def forget_crop(self) -> None:
        """A new photo (or none) starts from the centre again."""
        self.crop = None
        if self.dialog:
            self.dialog.close()

    def adjust_crop(self) -> "CropDialog | None":
        """Open the crop editor (Fill mode, a photo chosen); None if there is nothing to adjust."""
        if self.kind != "photo" or not self.path or self.app.fit.get() != "cover" or self.app.worker.busy:
            return None
        if self.dialog:
            self.dialog.win.lift()
            return self.dialog
        try:
            self.dialog = CropDialog(self.app, self)
        except Exception as e:  # the file changed or vanished since the preview
            self.show_preview_error(self.generation, e, os.path.basename(self.path))
            self.app.update_buttons()
        return self.dialog

    def set_path(self, path: str) -> None:
        self.forget_crop()
        self.path = path
        self.labels.put_text(self.name, os.path.basename(path))
        self.render()

    def clear(self) -> None:
        if self.app.worker.busy or self.kind != "photo":
            return
        self.path, self.frame = None, None
        self.forget_crop()
        self.generation += 1
        self.show_text("no_photo")
        self.labels.put(self.name)
        self.set_progress("", 0)
        self.app.update_buttons()

    def render(self) -> None:
        """(Re)compute the 7-colour photo preview on a background thread."""
        if not self.path or self.kind != "photo":
            return
        self.generation += 1
        gen, path, thumb_size_ = self.generation, self.path, self.thumb
        fit = self.app.fit.get()
        crop = self.crop if fit == "cover" else None  # Fit shows the whole photo; the crop is kept for later
        strength = image.GRAIN.get(self.app.grain.get(), 1.0)
        self.frame = None
        self.set_progress("making_preview", 0)
        self.app.update_buttons()

        def work() -> None:
            with self.app.preview_slots:  # at most two decodes at a time
                if gen != self.generation:
                    return  # superseded while waiting
                try:
                    with image.open_image(path) as src:
                        frame = image.encode(src, fit_mode=fit, strength=strength, crop=crop)
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
        self.canvas.configure(image=self.photo)
        self.labels.put(self.canvas)
        self.set_progress("preview_ready", 0)

    def show_preview_error(self, gen: int, error: BaseException, name: str) -> None:
        if gen != self.generation:
            return
        self.path, self.frame = None, None
        self.forget_crop()
        self.show_text("unreadable")
        self.labels.put(self.name)
        self.set_progress(lambda: preview_error_text(name, error), 0)  # kept as a function: a language switch redraws it

    def show_calendar(self, drawing: Image.Image) -> None:
        self.photo = ImageTk.PhotoImage(drawing.resize(self.thumb, Image.LANCZOS))
        self.canvas.configure(image=self.photo)
        self.labels.put(self.canvas)

    def set_progress(self, source: str | Callable[[], str], percent: int) -> None:
        """The status line under the preview: a text key, a function that makes the text, or "" for none."""
        self.labels.put(self.status, source)
        self.bar.configure(value=percent)


class CropDialog:
    """Choose which part of a photo fills the screen (Fill mode): see shared/CROP.md.

    The photo is the one the preview uses (image.open_image: oriented, capped at 4K), so every
    crop that passes here passes in Tile.render. The event handlers only call the small methods
    below (drag, drag_corner, wheel, set_zoom, key, reset, ok, cancel), which tests call directly.
    """

    VIEW = (800, 560)  # the photo is shown at most this big
    PAD = 12  # room around it, so the corner handles at its edge stay whole
    HANDLE = 10  # px
    WHEEL_STEP = 1.15

    def __init__(self, app: "App", tile: Tile) -> None:
        self.app, self.tile = app, tile
        with image.open_image(tile.path) as src:  # raises if the file changed since the preview
            self.photo_size = src.size
            shown = image._to_rgb(src)  # a copy; the capped photo itself is closed again below
        shown.thumbnail(self.VIEW, Image.LANCZOS)
        self.view_image = shown
        self.crop = crop_or_default(tile.crop, self.photo_size)
        self._grab: str | None = None
        self._last = (0, 0)
        self._syncing = False

        width, height = shown.size
        self.view = (self.PAD, self.PAD, self.PAD + width, self.PAD + height)
        self.win = tk.Toplevel(app.root)
        app.labels.put(self.win, "crop_title", "title", apply=self.win.title)
        self.win.transient(app.root)
        self.win.resizable(False, False)
        self.canvas = tk.Canvas(self.win, width=width + 2 * self.PAD, height=height + 2 * self.PAD, bg="#333",
                                highlightthickness=0, cursor="fleur")
        self.canvas.pack(padx=10, pady=(10, 4))
        self.tk_photo = ImageTk.PhotoImage(shown)
        self.canvas.create_image(self.PAD, self.PAD, anchor="nw", image=self.tk_photo)
        self.dim = [self.canvas.create_rectangle(0, 0, 0, 0, fill="black", stipple="gray50", outline="")
                    for _ in range(4)]
        self.outline = self.canvas.create_rectangle(0, 0, 0, 0, outline="white", width=1)
        self.thirds = [self.canvas.create_line(0, 0, 0, 0, fill="white") for _ in range(4)]
        self.handles = {corner: self.canvas.create_rectangle(0, 0, 0, 0, fill="white", outline="#222")
                        for corner in ("nw", "ne", "sw", "se")}

        app.labels.put(ttk.Label(self.win, foreground="#555", wraplength=self.VIEW[0]), "crop_help").pack(
            anchor="w", padx=10)
        zoom_row = ttk.Frame(self.win)
        zoom_row.pack(fill="x", padx=10, pady=4)
        app.labels.put(ttk.Label(zoom_row), "crop_zoom").pack(side="left")
        self.zoom = tk.DoubleVar(value=1.0)
        self.scale = ttk.Scale(zoom_row, from_=1, to=image.MAX_ZOOM, variable=self.zoom, takefocus=False,
                               command=lambda value: self.set_zoom(float(value)))
        self.scale.pack(side="left", fill="x", expand=True, padx=8)
        buttons = ttk.Frame(self.win)
        buttons.pack(fill="x", padx=10, pady=(0, 10))
        app.labels.put(ttk.Button(buttons, command=self.reset), "crop_reset").pack(side="left")
        app.labels.put(ttk.Button(buttons, command=self.ok), "crop_ok").pack(side="right")
        app.labels.put(ttk.Button(buttons, command=self.cancel), "cancel").pack(side="right", padx=6)

        self.canvas.bind("<ButtonPress-1>", self._press)
        self.canvas.bind("<B1-Motion>", self._motion)
        self.canvas.bind("<MouseWheel>", lambda e: self.wheel(1 if e.delta > 0 else -1))
        for name in ("Left", "Right", "Up", "Down"):
            self.canvas.bind(f"<{name}>", lambda e, name=name: self.key(name))
            self.canvas.bind(f"<Shift-{name}>", lambda e, name=name: self.key(name, shift=True))
        self.win.bind("<Escape>", lambda e: self.cancel())
        self.win.protocol("WM_DELETE_WINDOW", self.cancel)
        self.canvas.focus_set()
        self.redraw()

    # --- what the handlers do --------------------------------------------------

    def drag(self, dx_px: float, dy_px: float) -> None:
        x0, y0, x1, y1 = self.view
        self._set(move_crop(self.crop, dx_px / (x1 - x0), dy_px / (y1 - y0), self.photo_size))

    def drag_corner(self, corner: str, x_px: float, y_px: float) -> None:
        x, y = view_to_photo(x_px, y_px, self.photo_size, self.view)
        self._set(resize_crop(self.crop, corner, x, y, self.photo_size))

    def wheel(self, steps: int) -> None:
        self._set(zoom_crop(self.crop, self.WHEEL_STEP ** steps, self.photo_size))

    def set_zoom(self, level: float) -> None:
        if not self._syncing:
            self._set(zoom_crop(self.crop, level / zoom_level(self.crop, self.photo_size), self.photo_size))

    def key(self, name: str, shift: bool = False) -> None:
        self._set(nudge_crop(self.crop, name, shift, self.photo_size))

    def reset(self) -> None:
        self._set(image.default_crop(*self.photo_size))

    def ok(self) -> None:
        crop = None if self.crop == image.default_crop(*self.photo_size) else self.crop
        changed = crop != self.tile.crop
        self.close()
        if changed:
            self.tile.crop = crop
            self.tile.render()

    def cancel(self) -> None:
        self.close()

    def close(self) -> None:
        if self.tile.dialog is self:
            self.tile.dialog = None
        if self.win.winfo_exists():
            self.win.destroy()

    # --- drawing ---------------------------------------------------------------

    def _set(self, crop: image.Crop) -> None:
        self.crop = crop
        self.redraw()

    def _press(self, event: tk.Event) -> None:
        self.canvas.focus_set()
        corners = self._corners(photo_to_view(self.crop, self.photo_size, self.view))
        self._grab = next((c for c, (cx, cy) in corners.items()
                           if abs(event.x - cx) <= self.HANDLE and abs(event.y - cy) <= self.HANDLE), None)
        self._last = (event.x, event.y)

    def _motion(self, event: tk.Event) -> None:
        if self._grab:
            self.drag_corner(self._grab, event.x, event.y)
        else:
            self.drag(event.x - self._last[0], event.y - self._last[1])
            self._last = (event.x, event.y)

    @staticmethod
    def _corners(box: tuple[int, int, int, int]) -> dict[str, tuple[int, int]]:
        x0, y0, x1, y1 = box
        return {"nw": (x0, y0), "ne": (x1, y0), "sw": (x0, y1), "se": (x1, y1)}

    def redraw(self) -> None:
        vx0, vy0, vx1, vy1 = self.view
        x0, y0, x1, y1 = photo_to_view(self.crop, self.photo_size, self.view)
        c = self.canvas
        for item, box in zip(self.dim, ((vx0, vy0, vx1, y0), (vx0, y1, vx1, vy1), (vx0, y0, x0, y1), (x1, y0, vx1, y1))):
            c.coords(item, *box)
        c.coords(self.outline, x0, y0, x1, y1)
        w, h = x1 - x0, y1 - y0
        lines = [(x0 + w * i // 3, y0, x0 + w * i // 3, y1) for i in (1, 2)]
        lines += [(x0, y0 + h * i // 3, x1, y0 + h * i // 3) for i in (1, 2)]
        for item, line in zip(self.thirds, lines):
            c.coords(item, *line)
        half = self.HANDLE // 2
        for corner, (cx, cy) in self._corners((x0, y0, x1, y1)).items():
            c.coords(self.handles[corner], cx - half, cy - half, cx + half, cy + half)
        self._syncing = True  # moving the slider must not call set_zoom again
        try:
            self.zoom.set(zoom_level(self.crop, self.photo_size))
        finally:
            self._syncing = False


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
        self.labels = Labels()
        strings.set_language(strings.system_language())  # until the saved choice is known
        self.settings = config.Settings()
        self.settings_error: UlaniError | None = None  # why the saved settings would not load
        self.reload_settings(report=True)
        if self.settings.language:
            strings.set_language(self.settings.language)
        root.title("Paperhue")
        self.has_icon = set_window_icon(root)
        put = self.labels.put

        top = ttk.Frame(root, padding=(12, 10, 12, 0))
        top.pack(side="top", fill="x")
        self.device = ttk.Label(top)
        put(self.device, "device_unknown").pack(side="left")
        self.lang_btn = ttk.Button(top, command=self.toggle_language)  # named after the other language
        put(self.lang_btn, "language_toggle").pack(side="right")
        self.info_btn = ttk.Button(top, command=self.read_info)
        put(self.info_btn, "read_info").pack(side="right", padx=(0, 6))

        cal = ttk.Frame(root, padding=(12, 8, 12, 0))
        cal.pack(side="top", fill="x")
        self.feeds_label = ttk.Label(cal)
        self.feeds_label.grid(row=0, column=0, sticky="w")
        self.last_sync = ttk.Label(cal, foreground="#555")
        self.last_sync.grid(row=1, column=0, sticky="w")
        cal.columnconfigure(0, weight=1)
        buttons = ttk.Frame(cal)
        buttons.grid(row=0, column=1, rowspan=2, sticky="e")
        self.feeds_btn = ttk.Button(buttons, command=self.open_feeds)
        put(self.feeds_btn, "feeds_btn").pack(side="left")
        self.notes_btn = ttk.Button(buttons, command=self.open_notes)
        put(self.notes_btn, "notes_btn").pack(side="left", padx=(6, 0))
        self.sync_btn = ttk.Button(buttons, command=self.sync_now)
        put(self.sync_btn, "sync_btn").pack(side="left", padx=(6, 0))
        self.schedule_btn = ttk.Button(buttons, command=self.open_schedule)
        put(self.schedule_btn, "schedule_btn")
        if sys.platform == "win32":
            self.schedule_btn.pack(side="left", padx=(6, 0))

        opts = ttk.Frame(root, padding=(12, 6))
        opts.pack(side="top", fill="x")
        self.fit = tk.StringVar(value="cover")
        # a key of image.GRAIN, the saved one; the box shows its name
        self.grain = tk.StringVar(value=next((key for key, share in image.GRAIN.items()
                                              if share == self.settings.grain), next(iter(image.GRAIN))))
        grain = ttk.Combobox(opts, state="readonly", width=9)
        put(grain, lambda: [t(GRAIN_KEYS[k]) for k in image.GRAIN], "values")
        put(grain, lambda: t(GRAIN_KEYS[self.grain.get()]), "selection", apply=grain.set)
        grain.bind("<<ComboboxSelected>>", lambda e: self.grain_chosen())
        self.option_widgets = [
            put(ttk.Radiobutton(opts, value="cover", variable=self.fit, command=self.rerender), "fit_cover"),
            put(ttk.Radiobutton(opts, value="contain", variable=self.fit, command=self.rerender), "fit_contain"),
            put(ttk.Label(opts), "grain_label"),
            grain,
        ]
        for i, w in enumerate(self.option_widgets):
            w.pack(side="left", padx=(0 if i == 0 else 4 if w is grain else 12, 0))
        self.grain_box = grain

        # Packed before the grid and anchored to the bottom: on a short screen
        # the previews get clipped, never the push button.
        bottom = ttk.Frame(root, padding=(12, 0, 12, 12))
        bottom.pack(side="bottom", fill="x")
        self.push_btn = ttk.Button(bottom, command=self.push)
        put(self.push_btn, "push_btn").pack(side="right")
        self.summary = ttk.Label(bottom, wraplength=700, justify="left")
        put(self.summary, "summary_idle").pack(side="left")

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
            self.settings_error = None
        except UlaniError as e:
            self.settings_error = e  # self.settings stays as it was; never write it over the file
            if report:
                messagebox.showerror(t("settings_bad_title"), t("settings_bad", error=e))
        return self.settings

    def can_save(self) -> bool:
        """False (with the reason on screen) while the saved settings will not load:
        writing then would replace the file, and its feeds, with the defaults."""
        if self.settings_error is not None:
            messagebox.showerror(t("settings_bad_title"), t("settings_bad_kept", error=self.settings_error))
        return self.settings_error is None

    def save_settings(self) -> bool:
        if not self.can_save():
            return False
        try:
            config.save(self.settings)
        except (OSError, ValueError) as e:
            messagebox.showerror(t("settings_save_failed_title"), str(e))
            return False
        return True

    def toggle_language(self) -> None:
        self.set_language("en" if strings.language() == "zh" else "zh")

    def set_language(self, lang: str) -> None:
        """Show every text in ``lang`` now (main window and open dialogs) and remember the choice."""
        strings.set_language(lang)
        self.reload_settings().language = lang
        self.save_settings()
        self.labels.relabel()
        if self.feeds_dialog and self.feeds_dialog.win.winfo_exists():
            self.feeds_dialog.refresh()  # its list holds texts too (colour names)

    def refresh_feeds(self) -> None:
        names = [f.name for f in self.settings.feeds]
        if not self.calendar_ok:
            self.labels.put(self.feeds_label, "feeds_missing_pkg")
        elif names:
            self.labels.put(self.feeds_label, lambda: t("feeds_named", names=t("list_sep").join(names)))
        else:
            self.labels.put(self.feeds_label, "feeds_none")
        self.refresh_last()
        self.update_buttons()

    def refresh_last(self) -> None:
        last = syncjob.last()
        if not last:
            self.labels.put(self.last_sync, "last_sync_none")
            return
        try:
            when = f"{datetime.fromisoformat(last['time']):%m/%d %H:%M}"
        except (KeyError, ValueError):
            when = "?"
        ok, message = bool(last.get("ok")), str(last.get("message", ""))[:60]
        self.labels.put(self.last_sync, lambda: t(
            "last_sync", when=when, outcome=t("last_sync_ok") if ok else t("last_sync_failed", message=message)))

    def set_kind(self, slot: int, kind: str) -> None:
        tile = self.tiles[slot]
        if self.worker.busy:
            tile.combo.set(page_name(tile.kind))
            return
        self.reload_settings().pages[slot] = kind
        self.save_settings()
        tile.set_kind(kind)
        self.update_buttons()

    # --- actions -------------------------------------------------------------

    def grain_chosen(self) -> None:
        """Keep the grain in the settings: the scheduled sync and the cards draw with it too."""
        index = self.grain_box.current()  # the names are in image.GRAIN's order, in either language
        if index >= 0:
            self.grain.set(list(image.GRAIN)[index])
        self.reload_settings().grain = image.GRAIN[self.grain.get()]
        self.save_settings()
        self.rerender()

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
            t.adjust_btn.configure(
                state="normal" if photo_state == "normal" and t.path and self.fit.get() == "cover" else "disabled")
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
        """Some calendar page to draw, and the calendar packages. No source is needed: without one the
        public Taiwan holidays are shown. Board, card and photo pages are not redrawn by a sync."""
        return bool(settings.calendar_pages()) and self.calendar_ok

    def push(self) -> None:
        frames = self.frames()
        if not frames:
            return
        for slot, tile in self.tiles.items():
            if tile.kind == "photo":
                tile.set_progress("tile_waiting" if slot in frames else "", 0)

        async def job(report):
            return await self.push_fn(frames, lambda event: report("progress", event))

        if self.worker.submit(job, lambda msg: self.inbox.put(("push",) + msg)):
            self.job, self.unfinished = "push", set(frames)
            self.labels.put(self.summary, "push_start")
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
                self.tiles[slot].set_progress("tile_reading" if kind in CALENDAR_KINDS else "tile_preparing", 0)
            self.labels.put(self.summary, "sync_reading" if set(pages.values()) & set(CALENDAR_KINDS)
                            else "sync_preparing")
            self.update_buttons()

    def read_info(self) -> None:
        async def job(report):
            return await self.info_fn()

        if self.worker.submit(job, lambda msg: self.inbox.put(("info",) + msg)):
            self.job = "info"
            self.labels.put(self.device, "device_connecting")
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

    def say_post(self, source: str | Callable[[], str], error: bool = False) -> None:
        """Progress of a message board push (a text key or a function that makes the text): the
        status line, and the dialog if it is open."""
        self.labels.put(self.summary, source)
        if self.notes_dialog and self.notes_dialog.win.winfo_exists():
            self.notes_dialog.say(source, error)

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
            self.tiles[slot].set_progress("tile_waiting_send", 0)
        self.say_post("post_start")
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
            messagebox.showerror(t("schedule_error_title"), str(e))
            return
        win = tk.Toplevel(self.root)
        put = self.labels.put
        put(win, "schedule_title", "title", apply=win.title)
        win.transient(self.root)
        frm = ttk.Frame(win, padding=12)
        frm.pack(fill="both", expand=True)
        put(ttk.Label(frm, wraplength=440), "schedule_prompt").pack(anchor="w")
        entry = ttk.Entry(frm, width=40)
        entry.insert(0, ", ".join(current["times"] if current else self.reload_settings().times))
        entry.pack(anchor="w", pady=6)

        def state_text(st: dict | None) -> Callable[[], str]:
            return (lambda: t("schedule_on", times=", ".join(st["times"]))) if st else later("schedule_off")

        state = ttk.Label(frm)
        put(state, state_text(current)).pack(anchor="w")
        put(ttk.Label(frm, wraplength=440, foreground="#555"), "schedule_note").pack(anchor="w", pady=(6, 0))
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=(10, 0))

        def refresh_state() -> None:
            try:
                put(state, state_text(self.schedule_status_fn()))
            except Exception:
                pass

        put(ttk.Button(row, command=lambda: self.apply_schedule(entry.get()) and refresh_state()),
            "schedule_apply").pack(side="left")
        put(ttk.Button(row, command=lambda: (self.remove_schedule(), refresh_state())),
            "schedule_remove").pack(side="left", padx=6)
        put(ttk.Button(row, command=win.destroy), "close").pack(side="right")

    def apply_schedule(self, text: str) -> bool:
        try:
            times = parse_times(text)
        except ValueError as e:
            messagebox.showerror(t("time_bad_title"), str(e))
            return False
        self.reload_settings().times = times
        if not self.can_save():
            return False
        try:
            config.save(self.settings)
            self.schedule_install_fn(times)
        except Exception as e:
            messagebox.showerror(t("schedule_failed_title"), str(e))
            return False
        return True

    def remove_schedule(self) -> None:
        try:
            self.schedule_remove_fn()
        except Exception as e:
            messagebox.showerror(t("schedule_remove_failed_title"), str(e))

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
        """``unchanged``: the text key for a page that needed no push."""
        slot, _, percent = describe(event)
        text = later(unchanged) if event.phase == "unchanged" else (lambda: describe(event)[1])
        self.tiles[slot].set_progress(text, percent)
        if event.phase in ("done", "unchanged", "refreshing"):
            self.unfinished.discard(slot)

    def _mark_unfinished(self) -> None:
        for slot in sorted(self.unfinished):
            tile = self.tiles[slot]
            tile.set_progress("tile_unfinished", tile.bar.cget("value"))
        self.unfinished = set()

    def handle_push(self, what: str, value: Any) -> None:
        if what == "progress":
            self._progress(value, "progress_unchanged")
        elif what == "done":
            changed = sum(r is UploadResult.OK for r in value.values())
            same = len(value) - changed
            self.labels.put(self.summary, lambda: t("push_done", changed=pages(changed), same=pages(same)))
            self.labels.put(self.device, "device_pushed")
            self.unfinished = set()
        elif what == "error":
            self.labels.put(self.summary, "push_failed")
            self._mark_unfinished()
            messagebox.showerror(t("push_failed_title"), friendly(value))

    def handle_sync(self, what: str, value: Any) -> None:
        if what == "rendered":
            for slot, drawing in value.items():
                kind = self.sync_kinds.get(slot, "")
                self.calendar_images[slot] = (kind, drawing)
                if self.tiles[slot].kind == kind:
                    self.tiles[slot].show_calendar(drawing)
                self.tiles[slot].set_progress("tile_waiting_send", 0)
            self.labels.put(self.summary, "sync_rendered")
        elif what == "progress":
            self._progress(value, "progress_unchanged_sync")
        elif what == "done":
            syncjob.record(True, syncjob.describe(value))
            self.labels.put(self.summary, lambda: t("sync_done", message=syncjob.describe(value)))
            self.labels.put(self.device, "device_synced")
            self.unfinished = set()
            self.refresh_last()
        elif what == "error":
            syncjob.record(False, str(value) or type(value).__name__)
            self.labels.put(self.summary, "sync_failed")
            self._mark_unfinished()
            self.refresh_last()
            messagebox.showerror(t("sync_failed_title"), friendly(value))

    def handle_post(self, what: str, value: Any) -> None:
        if what == "rendered":
            self.say_post("post_rendered")
        elif what == "progress":
            self._progress(value, "progress_unchanged_sync")
            self.say_post(lambda: t("post_page", slot=value.slot, text=describe(value)[1]))
        elif what == "done":
            self.say_post(lambda: post_summary(value))
            self.labels.put(self.device, "device_posted")
            self.unfinished = set()
        elif what == "error":
            self.say_post("post_failed", error=True)
            self._mark_unfinished()
            messagebox.showerror(t("post_failed_title"), friendly(value))

    def handle_info(self, what: str, value: Any) -> None:
        if what == "done":
            battery, shown = value["battery"], value["shown"]
            self.labels.put(self.device, lambda: t(
                "device_battery", level=t("battery_charging") if battery.charging else f"{battery.level}/5",
                shown=shown))
        elif what == "error":
            self.labels.put(self.device, "device_unreachable")
            messagebox.showerror(t("info_failed_title"), friendly(value))

    def load_dropped(self, paths: list[str]) -> None:
        """Photos dropped onto the exe: one per photo page; if there are more
        photos than photo pages, offer to turn the first calendar pages into
        photo pages (the v0.2 behaviour was four photos on pages 1-4)."""
        paths = paths[: len(USER_SLOTS)]
        photo_slots = [s for s, t in self.tiles.items() if t.kind == "photo"]
        missing = len(paths) - len(photo_slots)
        if missing > 0:
            convert = [s for s, t in self.tiles.items() if t.kind != "photo"][:missing]
            names = t("list_sep").join(t("drop_name", slot=s, kind=page_name(self.tiles[s].kind)) for s in convert)
            if messagebox.askyesno(t("drop_title"), t("drop_ask", photos=len(paths), slots=len(photo_slots),
                                                        names=names)):
                for slot in convert:
                    self.set_kind(slot, "photo")
                photo_slots = sorted(photo_slots + convert)
        for slot, path in zip(photo_slots, paths):
            self.tiles[slot].set_path(path)
        if len(paths) > len(photo_slots):
            self.labels.put(self.summary, "drop_partial", n=len(photo_slots))

    def close(self) -> None:
        if self.job in ("push", "sync", "post") and not messagebox.askyesno(t("close_title"), t("close_text")):
            return
        self.worker.close()
        self.root.destroy()


class NotesDialog:
    """「留言」: write a note and post it to the message board pages; the notes so far, delete, clear."""

    def __init__(self, app: App) -> None:
        self.app = app
        self.win = win = tk.Toplevel(app.root)
        put = app.labels.put
        put(win, "notes_title", "title", apply=win.title)
        win.transient(app.root)
        frm = ttk.Frame(win, padding=12)
        frm.pack(fill="both", expand=True)
        self.help = ttk.Label(frm, wraplength=460, justify="left", foreground="#c00")  # set by update_buttons
        self.help.pack(anchor="w")
        put(ttk.Label(frm), "notes_text_label", max=note_store.MAX_TEXT, lines=note_store.MAX_LINES).pack(anchor="w")
        self.text = tk.Text(frm, width=46, height=5, wrap="char", undo=True)
        self.text.pack(fill="x", pady=(4, 0))
        self.text.bind("<<Modified>>", self._modified)
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=(6, 0))
        put(ttk.Label(row), "colour_label").pack(side="left")
        self.colour = tk.StringVar(value="yellow")
        self.colour_buttons = [put(ttk.Radiobutton(row, value=key, variable=self.colour), text_key)
                               for key, text_key in NOTE_COLOUR_KEYS.items()]
        for b in self.colour_buttons:
            b.pack(side="left", padx=(8, 0))
        self.counter = ttk.Label(row, text="", foreground="#555")
        self.counter.pack(side="right")
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=(8, 0))
        self.post_btn = ttk.Button(row, command=self.post)
        put(self.post_btn, "notes_post").pack(side="left")
        self.resend_btn = ttk.Button(row, command=self.resend)  # e.g. after a post that did not reach the device
        put(self.resend_btn, "notes_resend").pack(side="left", padx=(6, 0))
        self.status = ttk.Label(frm, wraplength=460, justify="left", foreground="#555")
        put(self.status, "notes_idle").pack(anchor="w", pady=(6, 0))
        put(ttk.Label(frm), "notes_posted").pack(anchor="w", pady=(10, 0))
        self.tree = ttk.Treeview(frm, columns=("time", "text"), show="headings", height=6, selectmode="browse")
        for col, key, width in (("time", "notes_col_time", 100), ("text", "notes_col_text", 360)):
            put(self.tree, key, f"heading-{col}", apply=lambda text, col=col: self.tree.heading(col, text=text))
            self.tree.column(col, width=width, anchor="w")
        self.tree.pack(fill="both", expand=True, pady=(4, 8))
        row = ttk.Frame(frm)
        row.pack(fill="x")
        self.remove_btn = ttk.Button(row, command=self.remove)
        put(self.remove_btn, "delete").pack(side="left")
        self.clear_btn = ttk.Button(row, command=self.clear)
        put(self.clear_btn, "notes_clear").pack(side="left", padx=6)
        put(ttk.Button(row, command=win.destroy), "close").pack(side="right")
        self.update_counter()
        self.refresh()
        self.text.focus_set()

    def say(self, source: str | Callable[[], str], error: bool = False, **fmt: Any) -> None:
        """Show a text (key, with its ``fmt``, or a function that makes it) in the status line."""
        self.app.labels.put(self.status, source, **fmt)
        self.status.configure(foreground="#c00" if error else "#555")

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
            self.say("plain", True, text=str(e))
            notes = []
        for n in notes:
            lines = n.text.split("\n")
            self.tree.insert("", "end", iid=n.id,
                             values=(note_store.when(n), lines[0] + (" …" if len(lines) > 1 else "")))
        self.update_buttons()

    def update_buttons(self) -> None:
        busy = self.app.worker.busy
        boards = bool(self.app.settings.board_pages())
        self.app.labels.put(self.help, "" if boards else "notes_no_board")
        self.post_btn.configure(state="normal" if boards and not busy else "disabled")
        self.resend_btn.configure(state="normal" if boards and not busy else "disabled")
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
            return self.say("plain", True, text=str(e))
        except (UlaniError, OSError) as e:
            return self.say("notes_save_failed", True, detail=str(e))
        self.text.delete("1.0", "end")
        self.update_counter()
        self._changed("auto")

    def resend(self) -> None:
        """Send the board pages again, with the notes as saved: no new note, the display stays where it is."""
        if not self.app.worker.busy:
            self.app.post_board("none")

    def remove(self) -> None:
        chosen = self.tree.selection()
        if self.app.worker.busy:
            return
        if not chosen:
            return self.say("notes_pick_first", True)
        try:
            note_store.remove(chosen[0])
        except (UlaniError, OSError) as e:
            return self.say("notes_delete_failed", True, detail=str(e))
        self.say("notes_deleted")
        self._changed("none")

    def clear(self) -> None:
        count = len(self.tree.get_children())
        if self.app.worker.busy or not count:
            return
        if not messagebox.askyesno(t("notes_clear"), t("notes_clear_ask", count=count), parent=self.win):
            return
        try:
            note_store.clear()
        except (UlaniError, OSError) as e:
            return self.say("notes_clear_failed", True, detail=str(e))
        self.say("notes_cleared")
        self._changed("none")


class FeedsDialog:
    """「行事曆來源」: the calendar sources (name, colour, host); add, edit, remove."""

    def __init__(self, app: App) -> None:
        self.app = app
        self.win = win = tk.Toplevel(app.root)
        put = app.labels.put
        put(win, "feeds_title", "title", apply=win.title)
        win.transient(app.root)
        frm = ttk.Frame(win, padding=12)
        frm.pack(fill="both", expand=True)
        put(ttk.Label(frm, wraplength=500, justify="left"), "feeds_help").pack(anchor="w")
        self.tree = ttk.Treeview(frm, columns=("name", "color", "host"), show="headings", height=6,
                                 selectmode="browse")
        for col, key, width in (("name", "feeds_col_name", 140), ("color", "feeds_col_colour", 70),
                                ("host", "feeds_col_source", 280)):
            put(self.tree, key, f"heading-{col}", apply=lambda text, col=col: self.tree.heading(col, text=text))
            self.tree.column(col, width=width, anchor="w")
        self.tree.pack(fill="both", expand=True, pady=8)
        row = ttk.Frame(frm)
        row.pack(fill="x")
        put(ttk.Button(row, command=self.add), "feed_add").pack(side="left")
        put(ttk.Button(row, command=self.edit), "feed_edit").pack(side="left", padx=6)
        put(ttk.Button(row, command=self.remove), "delete").pack(side="left")
        put(ttk.Button(row, command=win.destroy), "close").pack(side="right")
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
            host = feeds.where(info["url"]) if info and info.get("url") else t("feed_url_lost")
            colour = t(FEED_COLOUR_KEYS[f.color]) if f.color in FEED_COLOUR_KEYS else f.color
            self.tree.insert("", "end", iid=f.id, values=(f.name, colour, host))
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
        if not feed or not messagebox.askyesno(t("feed_delete_title"), t("feed_delete_ask", name=feed.name)):
            return
        settings = self.app.reload_settings()
        if not self.app.can_save():  # before the address leaves the credential store
            return
        current = settings.feed(feed.id)
        if current:
            try:
                feeds.remove_feed(settings, current, self.app.secrets)
            except Exception as e:
                messagebox.showerror(t("feed_delete_failed"), str(e))
                return
            self.app.save_settings()
        self.refresh()


class FeedForm:
    """Add or edit one source. A new address is checked by downloading it once before it is saved."""

    def __init__(self, dialog: FeedsDialog, feed: config.Feed | None) -> None:
        self.dialog, self.app, self.feed = dialog, dialog.app, feed
        self.old = dialog.secret(feed.id) if feed else None
        self.win = win = tk.Toplevel(dialog.win)
        put = self.app.labels.put
        name = feed.name if feed else ""
        put(win, "feed_new_title" if feed is None else (lambda: t("feed_edit_title", name=name)), "title",
            apply=win.title)
        win.transient(dialog.win)
        frm = ttk.Frame(win, padding=12)
        frm.pack(fill="both", expand=True)
        self.name = tk.StringVar(value=name)
        self.url = tk.StringVar()
        self.colour_key = feed.color if feed and feed.color in FEED_COLOUR_KEYS else ""
        self.colour = tk.StringVar(value=t(FEED_COLOUR_KEYS[self.colour_key]))  # the colour's name, as shown
        self.colour.trace_add("write", lambda *args: self._colour_written())
        self.user = tk.StringVar(value=(self.old or {}).get("user", ""))
        self.password = tk.StringVar()
        colours = ttk.Combobox(frm, textvariable=self.colour, state="readonly", width=10)
        put(colours, lambda: [t(key) for key in FEED_COLOUR_KEYS.values()], "values")
        put(colours, lambda: t(FEED_COLOUR_KEYS[self.colour_key]), "selection", apply=self.colour.set)
        fields = [
            ("feed_name", ttk.Entry(frm, textvariable=self.name, width=42)),
            ("feed_url_keep" if feed else "feed_url", ttk.Entry(frm, textvariable=self.url, width=42, show="•")),
            ("colour_label", colours),
            ("feed_user", ttk.Entry(frm, textvariable=self.user, width=42)),
            ("feed_password_keep" if feed else "feed_password",
             ttk.Entry(frm, textvariable=self.password, width=42, show="•")),
        ]
        for i, (label, widget) in enumerate(fields):
            put(ttk.Label(frm), label).grid(row=i, column=0, sticky="w", pady=3, padx=(0, 8))
            widget.grid(row=i, column=1, sticky="w", pady=3)
        self.status = ttk.Label(frm, wraplength=440, foreground="#555")
        put(self.status, "feed_hidden").grid(row=len(fields), column=0, columnspan=2, sticky="w", pady=(8, 0))
        row = ttk.Frame(frm)
        row.grid(row=len(fields) + 1, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        self.save_btn = ttk.Button(row, command=self.save)
        put(self.save_btn, "feed_check_save").pack(side="left")
        put(ttk.Button(row, command=win.destroy), "cancel").pack(side="right")
        self.pending: tuple | None = None

    def _colour_written(self) -> None:
        """The box shows a colour's name; ``colour_key`` is the colour, whatever the language."""
        shown = self.colour.get()
        self.colour_key = next((k for k, key in FEED_COLOUR_KEYS.items() if t(key) == shown), self.colour_key)

    def colour_value(self) -> str:
        return self.colour_key

    def say(self, source: str | Callable[[], str], error: bool = False, **fmt: Any) -> None:
        """Show a text (key, with its ``fmt``, or a function that makes it) in the status line."""
        self.app.labels.put(self.status, source, **fmt)
        self.status.configure(foreground="#c00" if error else "#555")

    def save(self) -> None:
        name, url = self.name.get().strip(), self.url.get().strip()
        user, password = self.user.get().strip(), self.password.get()
        if not name:
            return self.say("feed_need_name", True)
        if not url and not self.old:
            return self.say("feed_need_url", True)
        old = self.old or {}
        if self.feed and not url and not password and user == old.get("user", ""):
            return self.store(name, None, None, None)  # only the name or colour changed
        try:
            url = feeds.normalize_url(url or old.get("url", ""))
        except feeds.FeedError as e:
            return self.say("plain", True, text=str(e))
        old_user, old_password = feeds.login_for(old, url)  # another host: the old password is not reused
        if not password and user == old_user:
            password = old_password
        self.pending = (name, url, user, password)
        self.save_btn.configure(state="disabled")
        self.say("feed_reading", host=feeds.where(url))
        self.app.check_feed_async(self, url, user, password)

    def checked(self, what: str, value: Any) -> None:
        if not self.win.winfo_exists():
            return
        self.save_btn.configure(state="normal")
        if what == "error":
            return self.say("feed_unusable", True, detail=str(value))
        name, url, user, password = self.pending
        if self.store(name, url, user, password):
            self.app.labels.put(self.app.summary, "feed_saved", name=name, events=len(value.events),
                                tasks=len(value.tasks))

    def store(self, name: str, url: str | None, user: str | None, password: str | None) -> bool:
        settings = self.app.reload_settings()
        if not self.app.can_save():  # before the address goes into the credential store
            return False
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
            self.say("plain", True, text=str(e))
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
