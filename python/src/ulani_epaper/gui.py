"""Paperhue, the desktop app: put four photos onto the device (``paperhue``).

tkinter only (ships with Python), so the app has no extra dependencies.
Bluetooth runs on a BleWorker thread; the Tk thread only reads a queue.
UI text is Traditional Chinese on purpose: the device is sold in Taiwan.
"""

from __future__ import annotations

import base64
import os
import queue
import sys
import threading
import tkinter as tk
from importlib import resources
from tkinter import filedialog, messagebox, ttk
from typing import Any, Awaitable, Callable

from bleak.exc import BleakError
from PIL import Image, ImageTk, UnidentifiedImageError

from . import image, push
from .client import DeviceBusy, NoReply, PushEvent, UploadFailed, UploadResult, connect
from .gui_model import BleWorker, describe
from .protocol import USER_SLOTS, UlaniError

#: Largest preview size (5:3, like the panel).
THUMB = (384, 230)
#: Smallest preview height used on short screens.
MIN_THUMB_HEIGHT = 96
#: Vertical pixels (at 96 dpi) the OS takes outside the window: taskbar + title bar.
RESERVED = 80
IMAGE_TYPES = [("圖片", "*.jpg *.jpeg *.png *.bmp *.gif *.webp *.tif *.tiff"), ("所有檔案", "*.*")]
#: The app icon, package data in ulani_epaper/assets/ (made by shared/brand/make_icons.py).
ICON_ICO = "paperhue.ico"
ICON_PNGS = ("paperhue-256.png", "paperhue-32.png")

PushFn = Callable[[dict, Callable[[PushEvent], None]], Awaitable[dict]]
InfoFn = Callable[[], Awaitable[dict]]


async def default_push(frames: dict[int, bytes], progress: Callable[[PushEvent], None]) -> dict:
    return await push.push_frames(frames, progress=progress)


async def default_info() -> dict:
    async with connect() as cal:
        battery = await cal.battery()
        shown, _ = await cal.current_slot()
        return {"battery": battery, "shown": shown}


def thumb_size(screen_height: int, overhead: int = 400, reserved: int = RESERVED) -> tuple[int, int]:
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
    """A short explanation in Chinese, followed by the technical message."""
    text = str(error) or type(error).__name__
    if "Insufficient Authentication" in text or "Insufficient Encryption" in text:
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
    """One page: chosen file, encoded frame, preview widget, progress."""

    def __init__(self, parent: tk.Widget, slot: int, app: "App", thumb: tuple[int, int]) -> None:
        self.slot, self.app = slot, app
        self.path: str | None = None
        self.frame: bytes | None = None
        self.generation = 0
        self.photo: ImageTk.PhotoImage | None = None

        self.box = ttk.LabelFrame(parent, text=f"第 {slot} 頁", padding=8)
        self.canvas = tk.Label(self.box, bg="#e8e8e8", text="尚未選擇照片", fg="#666", compound="center")
        self.canvas.grid(row=0, column=0, columnspan=3)  # centred, never stretched
        self.canvas.bind("<Button-1>", lambda e: self.choose())
        self.name = ttk.Label(self.box, text="", width=40)
        self.name.grid(row=1, column=0, columnspan=3, sticky="w", pady=(6, 2))
        self.pick = ttk.Button(self.box, text="選擇照片…", command=self.choose)
        self.pick.grid(row=2, column=0, sticky="w")
        self.clear_btn = ttk.Button(self.box, text="清除", command=self.clear)
        self.clear_btn.grid(row=2, column=1, sticky="w", padx=6)
        self.bar = ttk.Progressbar(self.box, maximum=100, length=160)
        self.bar.grid(row=2, column=2, sticky="e")
        self.status = ttk.Label(self.box, text="", foreground="#555")
        self.status.grid(row=3, column=0, columnspan=3, sticky="w", pady=(4, 0))
        self.resize(thumb)

    def resize(self, thumb: tuple[int, int]) -> None:
        self.thumb = thumb
        self.blank = ImageTk.PhotoImage(Image.new("RGB", thumb, (232, 232, 232)))
        self.canvas.configure(width=thumb[0], height=thumb[1], image=self.blank)
        self.status.configure(wraplength=thumb[0])
        self.render()

    def choose(self) -> None:
        if self.app.worker.busy:
            return
        path = filedialog.askopenfilename(title=f"選擇第 {self.slot} 頁的照片", filetypes=IMAGE_TYPES)
        if path:
            self.set_path(path)

    def set_path(self, path: str) -> None:
        self.path = path
        self.name.configure(text=os.path.basename(path))
        self.render()

    def clear(self) -> None:
        if self.app.worker.busy:
            return
        self.path, self.frame = None, None
        self.generation += 1
        self.canvas.configure(image=self.blank, text="尚未選擇照片")
        self.name.configure(text="")
        self.set_progress("", 0)
        self.app.update_buttons()

    def render(self) -> None:
        """(Re)compute the 7-colour preview on a background thread."""
        if not self.path:
            return
        self.generation += 1
        gen, path, thumb_size_ = self.generation, self.path, self.thumb
        fit, dither = self.app.fit.get(), self.app.dither.get()
        self.frame = None
        self.set_progress("產生預覽中…", 0)
        self.app.update_buttons()

        def work() -> None:
            with self.app.preview_slots:  # at most two decodes at a time
                if gen != self.generation:
                    return  # superseded while waiting
                try:
                    with image.open_image(path) as src:
                        frame = image.encode(src, fit_mode=fit, dither=dither)
                    thumb = image.preview(frame).resize(thumb_size_, Image.LANCZOS)
                    self.app.inbox.put(("preview", self.slot, gen, frame, thumb))
                except Exception as e:  # unreadable file etc.
                    self.app.inbox.put(("preview-error", self.slot, gen, e, os.path.basename(path)))

        threading.Thread(target=work, daemon=True).start()

    def show_preview(self, gen: int, frame: bytes, thumb: Image.Image) -> None:
        if gen != self.generation:
            return  # superseded by a newer choice or option change
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

    def set_progress(self, text: str, percent: int) -> None:
        self.status.configure(text=text)
        self.bar.configure(value=percent)


class App:
    def __init__(self, root: tk.Misc, *, push_fn: PushFn = default_push, info_fn: InfoFn = default_info,
                 worker: BleWorker | None = None, thumb: tuple[int, int] | None = None) -> None:
        self.root, self.push_fn, self.info_fn = root, push_fn, info_fn
        self.worker = worker or BleWorker()
        self.inbox: queue.Queue = queue.Queue()
        self.preview_slots = threading.Semaphore(2)
        self.job: str | None = None  # "push" / "info" while the worker runs one
        self.unfinished: set[int] = set()  # pages of the current push not done yet
        root.title("Paperhue")
        self.has_icon = set_window_icon(root)

        top = ttk.Frame(root, padding=(12, 10, 12, 0))
        top.pack(side="top", fill="x")
        self.device = ttk.Label(top, text="裝置狀態：尚未讀取")
        self.device.pack(side="left")
        self.info_btn = ttk.Button(top, text="讀取狀態", command=self.read_info)
        self.info_btn.pack(side="right")

        opts = ttk.Frame(root, padding=(12, 6))
        opts.pack(side="top", fill="x")
        self.fit = tk.StringVar(value="cover")
        self.dither = tk.BooleanVar(value=True)
        self.option_widgets = [
            ttk.Radiobutton(opts, text="填滿畫面（裁切多餘部分）", value="cover", variable=self.fit,
                            command=self.rerender),
            ttk.Radiobutton(opts, text="完整顯示（留白邊）", value="contain", variable=self.fit,
                            command=self.rerender),
            ttk.Checkbutton(opts, text="抖色（照片建議開啟）", variable=self.dither, command=self.rerender),
        ]
        for i, w in enumerate(self.option_widgets):
            w.pack(side="left", padx=(0 if i == 0 else 12, 0))

        # Packed before the grid and anchored to the bottom: on a short screen
        # the previews get clipped, never the push button.
        bottom = ttk.Frame(root, padding=(12, 0, 12, 12))
        bottom.pack(side="bottom", fill="x")
        self.push_btn = ttk.Button(bottom, text="推送到裝置", command=self.push)
        self.push_btn.pack(side="right")
        self.summary = ttk.Label(bottom, text="選擇 1–4 張照片後按「推送到裝置」。正在顯示的那一頁會最後傳，"
                                              "全部約需 2 分鐘。")
        self.summary.pack(side="left")

        grid = ttk.Frame(root, padding=12)
        grid.pack(side="top", fill="both", expand=True)
        self.tiles = {slot: Tile(grid, slot, self, thumb or THUMB) for slot in USER_SLOTS}
        for i, tile in enumerate(self.tiles.values()):
            tile.box.grid(row=i // 2, column=i % 2, padx=6, pady=6, sticky="nsew")
        grid.columnconfigure((0, 1), weight=1)
        if thumb is None:
            self.fit_to_screen()

        self.update_buttons()
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

    # --- actions -------------------------------------------------------------

    def rerender(self) -> None:
        if self.worker.busy:
            return
        for tile in self.tiles.values():
            tile.render()

    def frames(self) -> dict[int, bytes]:
        return {slot: t.frame for slot, t in self.tiles.items() if t.frame is not None}

    def update_buttons(self) -> None:
        busy = self.worker.busy
        pending = any(t.path and t.frame is None for t in self.tiles.values())
        ready = bool(self.frames()) and not pending and not busy
        state = "disabled" if busy else "normal"
        self.push_btn.configure(state="normal" if ready else "disabled")
        self.info_btn.configure(state=state)
        for t in self.tiles.values():
            t.pick.configure(state=state)
            t.clear_btn.configure(state=state)
        for w in self.option_widgets:
            w.configure(state=state)

    def push(self) -> None:
        frames = self.frames()
        if not frames:
            return
        for slot, tile in self.tiles.items():
            tile.set_progress("等待中" if slot in frames else "", 0)

        async def job(report):
            return await self.push_fn(frames, lambda event: report("progress", event))

        if self.worker.submit(job, lambda msg: self.inbox.put(("push",) + msg)):
            self.job, self.unfinished = "push", set(frames)
            self.summary.configure(text="連線並推送中…（正在顯示的那一頁會最後傳）")
            self.update_buttons()

    def read_info(self) -> None:
        async def job(report):
            return await self.info_fn()

        if self.worker.submit(job, lambda msg: self.inbox.put(("info",) + msg)):
            self.job = "info"
            self.device.configure(text="裝置狀態：連線中…")
            self.update_buttons()

    # --- messages from worker threads -------------------------------------------

    def poll(self) -> None:
        try:
            while True:
                self.handle(self.inbox.get_nowait())
        except queue.Empty:
            pass
        self.root.after(100, self.poll)

    def handle(self, msg: tuple) -> None:
        kind = msg[0]
        if kind == "preview":
            _, slot, gen, frame, thumb = msg
            self.tiles[slot].show_preview(gen, frame, thumb)
        elif kind == "preview-error":
            _, slot, gen, error, name = msg
            self.tiles[slot].show_preview_error(gen, error, name)
        elif kind in ("push", "info"):
            if msg[1] in ("done", "error"):
                self.job = None
            (self.handle_push if kind == "push" else self.handle_info)(msg[1], msg[2])
        self.update_buttons()

    def handle_push(self, what: str, value: Any) -> None:
        if what == "progress":
            slot, text, percent = describe(value)
            self.tiles[slot].set_progress(text, percent)
            if value.phase in ("done", "unchanged", "refreshing"):
                self.unfinished.discard(slot)
        elif what == "done":
            changed = sum(r is UploadResult.OK for r in value.values())
            self.summary.configure(text=f"完成：{changed} 頁已更新，{len(value) - changed} 頁原本就相同。")
            self.device.configure(text="裝置狀態：剛完成推送（按「讀取狀態」可更新）")
            self.unfinished = set()
        elif what == "error":
            self.summary.configure(text="推送失敗，請看錯誤訊息後再試一次。")
            for slot in sorted(self.unfinished):
                tile = self.tiles[slot]
                tile.set_progress("未完成", tile.bar.cget("value"))
            self.unfinished = set()
            messagebox.showerror("推送失敗", friendly(value))

    def handle_info(self, what: str, value: Any) -> None:
        if what == "done":
            battery = value["battery"]
            level = "充電中" if battery.charging else f"{battery.level}/5"
            self.device.configure(text=f"裝置狀態：電量 {level}，目前顯示第 {value['shown']} 頁")
        elif what == "error":
            self.device.configure(text="裝置狀態：連不上")
            messagebox.showerror("讀取狀態失敗", friendly(value))

    def close(self) -> None:
        if self.job == "push" and not messagebox.askyesno(
                "仍在傳送", "照片還在傳送中，現在關閉會中斷傳送。確定要關閉嗎？"):
            return
        self.worker.close()
        self.root.destroy()


def _enable_dpi_awareness() -> None:
    if sys.platform == "win32":
        try:
            import ctypes

            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass


def main(argv: list[str] | None = None) -> None:
    """Start the app. Image paths given on the command line (or dropped onto
    the .exe in Explorer) are loaded into pages 1-4."""
    paths = (sys.argv[1:] if argv is None else argv)[: len(USER_SLOTS)]
    Image.MAX_IMAGE_PIXELS = image.MAX_PHOTO_PIXELS  # the user's own photos (200 MP phones)
    _enable_dpi_awareness()
    root = tk.Tk()
    app = App(root)
    for slot, path in zip(USER_SLOTS, paths):
        app.tiles[slot].set_path(path)
    root.mainloop()


if __name__ == "__main__":
    main()
