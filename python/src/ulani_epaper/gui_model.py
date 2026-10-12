"""Tk-free logic of the desktop app, kept separate so it can be unit-tested.

UI text is Traditional Chinese on purpose: the device is sold in Taiwan.
"""

from __future__ import annotations

import asyncio
import re
import threading
import unicodedata
from typing import Any, Awaitable, Callable

from .client import PushEvent

Report = Callable[[str, Any], None]
Job = Callable[[Report], Awaitable[Any]]
Post = Callable[[tuple], None]


def describe(event: PushEvent) -> tuple[int, str, int]:
    """(page, status text, percent) for one push progress event."""
    if event.phase == "start":
        return event.slot, f"準備傳送（{event.index + 1}/{event.count}）", 0
    if event.phase == "sending":
        percent = event.sent * 100 // event.total if event.total else 0
        return event.slot, f"傳送中 {percent}%", percent
    if event.phase == "unchanged":
        return event.slot, "已是這張照片，略過", 100
    if event.phase == "refreshing":
        return event.slot, "完成（畫面約需 40 秒刷新）", 100
    if event.phase == "switching":
        return event.slot, "切換顯示這一頁（畫面約需 40 秒刷新）", 100
    return event.slot, "完成", 100


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
            raise ValueError(f"「{part}」不是有效的時間，請用 24 小時制，例如 06:00")
        times.add(f"{int(m[1]):02d}:{m[2]}")
    if not times:
        raise ValueError("請至少輸入一個時間，例如 06:00")
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
