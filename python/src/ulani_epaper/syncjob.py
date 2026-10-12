"""The scheduled sync: ``pythonw -m ulani_epaper.syncjob`` or ``Paperhue.exe --sync``.

Runs one sync with the saved settings, retrying a few times (after waking
from sleep, Wi-Fi or Bluetooth may not be back yet), and appends the
outcome to sync-log.jsonl in the config folder: time, success, and which
pages changed with event/task counts. Never titles or other content.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Callable

from . import config, sync
from .agenda import LOCAL
from .client import UploadResult
from .feeds import NoFeeds
from .protocol import UlaniError

KEEP = 200  # runs kept in the log
ATTEMPTS = 3
WAIT = 120  # seconds between attempts


def log_path() -> Path:
    return config.config_dir() / "sync-log.jsonl"


def _entries() -> list[dict]:
    """Every readable entry; a damaged line (power cut, hand edit) is skipped."""
    try:
        text = log_path().read_bytes().decode("utf-8", errors="replace")
    except OSError:
        return []
    entries = []
    for line in text.splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and {"time", "ok", "message"} <= entry.keys():
            entries.append(entry)
    return entries


def record(ok: bool, message: str) -> bool:
    """Append one run to the log (atomically). Never raises: a log that cannot
    be written must not turn a good sync into a failure."""
    entry = {"time": datetime.now(LOCAL).isoformat(timespec="seconds"), "ok": ok, "message": message}
    lines = [json.dumps(e, ensure_ascii=False) for e in (_entries() + [entry])[-KEEP:]]
    path = log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".sync-log-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            os.replace(tmp, path)
        except BaseException:
            os.unlink(tmp)
            raise
    except OSError:
        return False
    return True


def last() -> dict | None:
    """The most recent run: {"time", "ok", "message"}, or None. Never raises."""
    entries = _entries()
    return entries[-1] if entries else None


def describe(report: sync.SyncReport) -> str:
    if not report.pages:
        return "沒有設定成行事曆或待辦的頁面"
    outcome = {UploadResult.OK: "已更新", UploadResult.UNCHANGED: "沒有變化"}
    pages = "；".join(
        f"第 {slot} 頁 {config.PAGE_NAMES[kind]}："
        + (outcome[report.results[slot]] if report.results and slot in report.results else "已繪製（未推送）")
        for slot, kind in sorted(report.pages.items()))
    kinds = set(report.pages.values())
    counts = []
    if kinds & set(config.CALENDAR_KINDS):
        counts.append(f"{report.events} 個行程、{report.tasks} 項待辦")
    if kinds & set(config.BOARD_KINDS):
        counts.append(f"{report.notes} 則留言")
    return pages + (f"（{'、'.join(counts)}）" if counts else "")


def _sync(settings: config.Settings) -> sync.SyncReport:
    return asyncio.run(sync.sync(settings))


def main(argv: list[str] | None = None, *, sync_fn: Callable[[config.Settings], sync.SyncReport] = _sync,
         sleep: Callable[[float], None] | None = time.sleep, attempts: int = ATTEMPTS, wait: float = WAIT) -> int:
    try:
        settings = config.load()
    except UlaniError as e:
        record(False, str(e))
        return 1
    for attempt in range(1, attempts + 1):
        try:
            report = sync_fn(settings)
        except NoFeeds as e:  # nothing to retry until the user adds a calendar
            record(False, str(e))
            return 2
        except Exception as e:  # noqa: BLE001 - logged; the next scheduled run tries again
            if attempt == attempts:
                record(False, str(e) or type(e).__name__)
                return 1
            record(False, f"第 {attempt} 次失敗，{wait:g} 秒後重試：{e}")
            sleep(wait)
            continue
        record(True, describe(report))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
