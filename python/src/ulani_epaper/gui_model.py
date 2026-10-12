"""Tk-free logic of the desktop app, kept separate so it can be unit-tested.

Its texts come from strings.py, in the language the user chose.
"""

from __future__ import annotations

import asyncio
import math
import re
import threading
import unicodedata
from typing import Any, Awaitable, Callable

from . import image
from .client import PushEvent
from .strings import t

Report = Callable[[str, Any], None]
Job = Callable[[Report], Awaitable[Any]]
Post = Callable[[tuple], None]


def describe(event: PushEvent) -> tuple[int, str, int]:
    """(page, status text, percent) for one push progress event."""
    if event.phase == "start":
        return event.slot, t("progress_start", n=event.index + 1, count=event.count), 0
    if event.phase == "sending":
        percent = event.sent * 100 // event.total if event.total else 0
        return event.slot, t("progress_sending", percent=percent), percent
    key = {"unchanged": "progress_unchanged", "refreshing": "progress_refreshing",
           "switching": "progress_switching"}.get(event.phase, "progress_done")
    return event.slot, t(key), 100


def parse_times(text: str) -> list[str]:
    """ "18:00，7:30、12:00" -> ["07:30", "12:00", "18:00"]; ValueError if any is not H:MM.

    Full-width input from a Chinese IME (１８：００) is accepted as well."""
    times = set()
    text = unicodedata.normalize("NFKC", text)
    for part in re.split(r"[\s,，、;；]+", text.strip()):
        if not part:
            continue
        m = re.fullmatch(r"([0-9]{1,2}):([0-9]{2})", part)
        if not m or int(m[1]) > 23 or int(m[2]) > 59:
            raise ValueError(t("time_bad", part=part))
        times.add(f"{int(m[1]):02d}:{m[2]}")
    if not times:
        raise ValueError(t("time_missing"))
    return sorted(times)


class BleWorker:
    """Runs one BLE job at a time on a private asyncio loop in a daemon thread.

    bleak's WinRT backend must not run on the Tk thread, and Tk must only be
    touched from its own thread, so jobs talk back through ``post`` (e.g.
    ``queue.Queue.put``) with tuples: ``(kind, value)`` from ``report``, then
    ``("done", result)`` or ``("error", exception)``.
    """

    def __init__(self) -> None:
        self._loop = asyncio.new_event_loop()
        self._lock = threading.Lock()
        self._busy = False
        self._thread = threading.Thread(target=self._run, name="ulani-ble", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    @property
    def busy(self) -> bool:
        return self._busy

    def submit(self, job: Job, post: Post) -> bool:
        """Start ``job(report)`` unless another job is running; returns whether it started."""
        with self._lock:
            if self._busy:
                return False
            self._busy = True

        async def runner() -> None:
            try:
                result = await job(lambda kind, value=None: post((kind, value)))
            except Exception as e:  # reported to the UI, never raised into the loop
                outcome: tuple = ("error", e)
            else:
                outcome = ("done", result)
            with self._lock:
                self._busy = False
            post(outcome)

        asyncio.run_coroutine_threadsafe(runner(), self._loop)
        return True

    def close(self, cleanup_timeout: float = 5.0) -> None:
        """Cancel a running job (letting its cleanup, e.g. a BLE disconnect,
        run for up to ``cleanup_timeout`` s), then stop and release the loop.
        Idempotent."""
        if self._loop.is_closed():
            return

        async def cancel_jobs() -> None:
            jobs = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
            for job in jobs:
                job.cancel()
            await asyncio.gather(*jobs, return_exceptions=True)

        try:
            asyncio.run_coroutine_threadsafe(cancel_jobs(), self._loop).result(timeout=cleanup_timeout)
        except Exception:  # cleanup took too long; stop anyway
            pass
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=2)
        if not self._thread.is_alive():
            self._loop.close()


# --- photo crop editing (pure; ``photo`` is the (width, height) of the oriented, capped photo) -----

Photo = tuple[int, int]
View = tuple[int, int, int, int]
_SHAPE = image.WIDTH / image.HEIGHT  # the screen's 5:3


def _height(width: float, photo: Photo) -> float:
    """Crop height (a fraction of the photo) for a crop ``width`` wide, in the screen's shape."""
    return width * photo[0] / photo[1] / _SHAPE


def _width_range(photo: Photo) -> tuple[float, float]:
    """Smallest and largest crop width (fractions of the photo)."""
    largest = image.default_crop(*photo)
    floor_px = min(image.MIN_CROP_PX, largest[3] * photo[1])
    return max(largest[2] / image.MAX_ZOOM, floor_px * _SHAPE / photo[0]), largest[2]


def _place(left: float, top: float, width: float, photo: Photo) -> image.Crop:
    """A crop ``width`` wide (clamped to the allowed sizes), moved to lie inside the photo."""
    low, high = _width_range(photo)
    width = min(max(width, low), high)
    height = _height(width, photo)
    return (min(max(left, 0.0), 1 - width), min(max(top, 0.0), 1 - height), width, height)


def crop_or_default(crop: image.Crop | None, photo: Photo) -> image.Crop:
    return image.default_crop(*photo) if crop is None else crop


def move_crop(crop: image.Crop, dx: float, dy: float, photo: Photo) -> image.Crop:
    """Move by ``dx``, ``dy`` (fractions of the photo), staying inside it."""
    return _place(crop[0] + dx, crop[1] + dy, crop[2], photo)


def zoom_crop(crop: image.Crop, factor: float, photo: Photo) -> image.Crop:
    """Zoom in by ``factor`` (> 1) or out (< 1) about the centre of the crop."""
    left, top, width, height = crop
    low, high = _width_range(photo)
    new = min(max(width / factor, low), high)
    if new == width:
        return crop
    return _place(left + (width - new) / 2, top + (height - _height(new, photo)) / 2, new, photo)


def zoom_level(crop: image.Crop, photo: Photo) -> float:
    """1.0 for the default crop, up to 8.0."""
    return image.default_crop(*photo)[2] / crop[2]


def resize_crop(crop: image.Crop, corner: str, x: float, y: float, photo: Photo) -> image.Crop:
    """Drag ``corner`` ("nw", "ne", "sw", "se") to the pointer ``x``, ``y`` (fractions of the photo);
    the opposite corner stays where it is and the shape stays 5:3."""
    left, top, width, height = crop
    east, south = corner[1] == "e", corner[0] == "s"
    anchor_x = left if east else left + width
    anchor_y = top if south else top + height
    # the pointer decides the size: whichever of its two distances asks for the bigger crop
    wanted = max(abs(x - anchor_x), abs(y - anchor_y) * _SHAPE * photo[1] / photo[0])
    low, high = _width_range(photo)
    room_x = 1 - anchor_x if east else anchor_x
    room_y = 1 - anchor_y if south else anchor_y
    new = min(max(wanted, low), high, room_x, room_y * photo[1] * _SHAPE / photo[0])
    new_height = _height(new, photo)
    return _place(anchor_x if east else anchor_x - new, anchor_y if south else anchor_y - new_height, new, photo)


def nudge_crop(crop: image.Crop, key: str, shift: bool, photo: Photo) -> image.Crop:
    """An arrow key: 1 % of the photo, 10 % with Shift."""
    step = 0.1 if shift else 0.01
    dx, dy = {"Left": (-step, 0), "Right": (step, 0), "Up": (0, -step), "Down": (0, step)}[key]
    return move_crop(crop, dx, dy, photo)


def _round(value: float) -> int:
    return math.floor(value + 0.5)


def photo_to_view(crop: image.Crop, photo: Photo, view: View) -> View:
    """The crop's rectangle on a canvas where the photo is shown at ``view`` (x0, y0, x1, y1)."""
    x0, y0, x1, y1 = view
    left, top, width, height = crop
    return (_round(x0 + left * (x1 - x0)), _round(y0 + top * (y1 - y0)),
            _round(x0 + (left + width) * (x1 - x0)), _round(y0 + (top + height) * (y1 - y0)))


def view_to_photo(x: float, y: float, photo: Photo, view: View) -> tuple[float, float]:
    """A canvas point as fractions of the photo."""
    x0, y0, x1, y1 = view
    return (x - x0) / (x1 - x0), (y - y0) / (y1 - y0)


# --- card text boxes (pure; a box is (left, top, width, height) as fractions of the screen) -----

Box = tuple[float, float, float, float]
MIN_BOX = 0.05  # the smallest side of a text box


def move_box(box: Box, dx: float, dy: float) -> Box:
    """Move by ``dx``, ``dy``, staying on the screen."""
    left, top, width, height = box
    return min(max(left + dx, 0.0), 1 - width), min(max(top + dy, 0.0), 1 - height), width, height


def resize_box(box: Box, corner: str, x: float, y: float) -> Box:
    """Drag ``corner`` ("nw", "ne", "sw", "se") to ``x``, ``y``: the opposite corner stays, the box stays on the
    screen and at least MIN_BOX on each side."""
    left, top, width, height = box
    east, south = corner[1] == "e", corner[0] == "s"
    anchor_x, anchor_y = (left if east else left + width), (top if south else top + height)
    x = max(min(x, 1.0), anchor_x + MIN_BOX) if east else min(max(x, 0.0), anchor_x - MIN_BOX)
    y = max(min(y, 1.0), anchor_y + MIN_BOX) if south else min(max(y, 0.0), anchor_y - MIN_BOX)
    return min(x, anchor_x), min(y, anchor_y), abs(x - anchor_x), abs(y - anchor_y)
