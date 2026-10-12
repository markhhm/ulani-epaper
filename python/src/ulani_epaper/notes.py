"""The message board's notes (留言板): short messages the owner writes for the device.

Kept in notes.json in the config folder (see config.config_dir()), newest
first, written atomically like settings.json. Unlike calendar data, which is
never stored, these are the owner's own words, so keeping them is fine.

    {"version": 1, "notes": [{"id": "a1b2c3d4", "text": "...",
                              "at": "2026-10-12T14:03:00+08:00", "color": "yellow"}]}
"""

from __future__ import annotations

import json
import os
import re
import secrets
import tempfile
import unicodedata
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

from . import config
from .agenda import LOCAL
from .protocol import UlaniError

__all__ = ["MAX_LINES", "MAX_NOTES", "MAX_TEXT", "NOTE_COLOURS", "Note", "add", "check_text", "clear", "load",
           "normalize", "notes_path", "remove", "save"]

VERSION = 1
NOTE_COLOURS = ("yellow", "orange", "green", "blue", "red")
MAX_NOTES = 50  # adding one more drops the oldest
MAX_TEXT = 300  # characters, after normalize()
MAX_LINES = 8

_ID = re.compile(r"[0-9a-f]{8}")


@dataclass(frozen=True)
class Note:
    id: str  # 8 hex characters, unique within the file
    text: str  # normalized: NFC, "\n" line breaks, no outer whitespace
    at: str  # when it was written: ISO 8601 with a UTC offset
    color: str = "yellow"  # one of NOTE_COLOURS

    def written(self) -> datetime:
        """``at`` as an aware datetime."""
        return datetime.fromisoformat(self.at)


def notes_path() -> Path:
    return config.config_dir() / "notes.json"


def normalize(text: str) -> str:
    """The text as it is stored: composed (NFC), "\\n" line breaks, stripped.
    ``len(normalize(text))`` is what counts against MAX_TEXT."""
    text = unicodedata.normalize("NFC", text or "")
    return text.replace("\r\n", "\n").replace("\r", "\n").strip()


def check_text(text: str) -> str:
    """normalize() ``text``, or ValueError (in Traditional Chinese) if it cannot be a note."""
    text = normalize(text)
    if not text:
        raise ValueError("留言是空的")
    if len(text) > MAX_TEXT:
        raise ValueError(f"留言最多 {MAX_TEXT} 字（目前 {len(text)} 字）")
    if text.count("\n") + 1 > MAX_LINES:
        raise ValueError(f"留言最多 {MAX_LINES} 行")
    return text


def _check_colour(color: str) -> None:
    if color not in NOTE_COLOURS:
        raise ValueError(f"留言的顏色必須是 {', '.join(NOTE_COLOURS)} 之一，收到 {color!r}")


def _validate(notes: Iterable[Note]) -> list[Note]:
    notes = list(notes)
    if len(notes) > MAX_NOTES:
        raise ValueError(f"at most {MAX_NOTES} notes, got {len(notes)}")
    seen = set()
    for n in notes:
        if not all(isinstance(v, str) for v in (n.id, n.text, n.at, n.color)):
            raise ValueError(f"note fields must be strings: {n!r}")
        if not _ID.fullmatch(n.id) or n.id in seen:
            raise ValueError(f"note ids must be 8 hex characters and unique, got {n.id!r}")
        seen.add(n.id)
        if check_text(n.text) != n.text:
            raise ValueError(f"note {n.id}: text is not normalized")
        if n.written().tzinfo is None:
            raise ValueError(f"note {n.id}: time {n.at!r} has no UTC offset")
        _check_colour(n.color)
    return notes


def load(path: str | os.PathLike | None = None) -> list[Note]:
    """The notes, newest first. A missing file means no notes; a file that
    cannot be read or is invalid raises UlaniError (it is never overwritten)."""
    path = Path(path or notes_path())
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as e:
        raise UlaniError(f"cannot read the notes file {path}: {e}") from None
    try:
        if raw.get("version") != VERSION:
            raise ValueError(f"unknown version {raw.get('version')!r}")
        return _validate(Note(n["id"], n["text"], n["at"], n.get("color", "yellow")) for n in raw["notes"])
    except (TypeError, ValueError, AttributeError, KeyError) as e:
        raise UlaniError(f"the notes file {path} is invalid: {e!r}") from None


def save(notes: Iterable[Note], path: str | os.PathLike | None = None) -> None:
    notes = _validate(notes)
    path = Path(path or notes_path())
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = {"version": VERSION, "notes": [asdict(n) for n in notes]}
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".notes-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(raw, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def _new_id(taken: set[str]) -> str:
    while True:
        candidate = secrets.token_hex(4)
        if candidate not in taken:
            return candidate


def add(text: str, color: str = "yellow", now: datetime | None = None,
        path: str | os.PathLike | None = None) -> Note:
    """Save a new note on top; beyond MAX_NOTES the oldest is dropped.
    ValueError if the text or colour is not acceptable."""
    text = check_text(text)
    _check_colour(color)
    notes = load(path)
    now = now or datetime.now(LOCAL)
    if now.tzinfo is None:
        now = now.replace(tzinfo=LOCAL)
    at = now.replace(microsecond=0).isoformat()
    note = Note(_new_id({n.id for n in notes}), text, at, color)
    save([note] + notes[:MAX_NOTES - 1], path)
    return note


def _find(notes: list[Note], key: str | int) -> int:
    k = str(key).strip().lower()
    for i, n in enumerate(notes):
        if n.id == k:
            return i
    if re.fullmatch(r"[0-9]+", k) and 1 <= int(k) <= len(notes):
        return int(k) - 1
    raise UlaniError(f"沒有這則留言：{key}（請用留言的代碼，或 1 到 {len(notes)} 的編號）" if notes
                     else "目前沒有留言")


def remove(key: str | int, path: str | os.PathLike | None = None) -> Note:
    """Delete one note by id or by its 1-based position (newest = 1); returns it."""
    notes = load(path)
    note = notes.pop(_find(notes, key))
    save(notes, path)
    return note


def clear(path: str | os.PathLike | None = None) -> int:
    """Delete every note; returns how many there were."""
    notes = load(path)
    if notes:
        save([], path)
    return len(notes)
