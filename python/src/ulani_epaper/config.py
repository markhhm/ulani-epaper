"""Settings for the calendar pages: what each page shows, which calendar
feeds (by id, name and colour; their addresses are secrets kept in the OS
credential store by feeds.py), when to sync. They hold no calendar content
(that is never stored).

Kept as JSON in the user's config folder: %APPDATA%\\ulani-epaper on
Windows, ~/Library/Application Support/ulani-epaper on macOS,
$XDG_CONFIG_HOME/ulani-epaper elsewhere (ULANI_CONFIG_DIR overrides).
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .protocol import USER_SLOTS, UlaniError

PAGE_KINDS = ("photo", "month", "agenda", "todo", "board", "message", "card")
PAGE_NAMES = {"photo": "照片", "month": "月曆", "agenda": "一週行程", "todo": "待辦清單",
              "board": "留言板", "message": "大字留言", "card": "牌卡"}
CALENDAR_KINDS = ("month", "agenda", "todo")  # drawn from the calendar feeds
BOARD_KINDS = ("board", "message")  # drawn from the notes (notes.py), no network needed
CARD_KINDS = ("card",)  # shows a saved card (cards.py), pushed on request; sync never redraws it
DEFAULT_PAGES = {1: "month", 2: "agenda", 3: "todo", 4: "photo"}
DEFAULT_TIMES = ["06:00", "12:00", "18:00"]
#: feed colours: a panel colour name, "#rrggbb", or "" (chosen automatically)
FEED_COLOURS = ("red", "orange", "yellow", "green", "blue", "black")


@dataclass
class Feed:
    """One calendar source. Its .ics address lives in the credential store under ``id``."""

    id: str
    name: str  # shown on the pages ("個人", "學校")
    color: str = ""


@dataclass
class Settings:
    #: page (1-4) -> one of PAGE_KINDS; "photo" and "card" pages are left alone by sync
    pages: dict[int, str] = field(default_factory=lambda: dict(DEFAULT_PAGES))
    #: calendar sources (.ics addresses), in display order
    feeds: list[Feed] = field(default_factory=list)
    #: daily sync times, "HH:MM" local time
    times: list[str] = field(default_factory=lambda: list(DEFAULT_TIMES))
    #: the device's Bluetooth address; None = find it by name
    address: str | None = None

    def validate(self) -> None:
        for slot, kind in self.pages.items():
            if slot not in USER_SLOTS:
                raise ValueError(f"pages are 1-4, got {slot}")
            if kind not in PAGE_KINDS:
                raise ValueError(f"page {slot}: unknown kind {kind!r} (one of {', '.join(PAGE_KINDS)})")
        ids = [f.id for f in self.feeds]
        if len(set(ids)) != len(ids) or not all(re.fullmatch(r"[0-9A-Za-z_-]{1,40}", i) for i in ids):
            raise ValueError(f"feed ids must be unique and simple, got {ids}")
        for f in self.feeds:
            if not f.name.strip():
                raise ValueError("every feed needs a name")
            if f.color and f.color not in FEED_COLOURS and not re.fullmatch(r"#[0-9a-fA-F]{6}", f.color):
                raise ValueError(f"feed {f.name}: colour must be one of {', '.join(FEED_COLOURS)} or #rrggbb")
        if not self.times:
            raise ValueError("at least one sync time is needed")
        for t in self.times:
            m = re.fullmatch(r"([0-9]{2}):([0-9]{2})", t)  # not \d: it also matches full-width digits
            if not m or int(m[1]) > 23 or int(m[2]) > 59:
                raise ValueError(f"sync times are HH:MM, got {t!r}")
        self.times = sorted(set(self.times))

    def feed(self, key: str) -> Feed | None:
        """A feed by id or (case-insensitive) name."""
        return next((f for f in self.feeds if key in (f.id,) or f.name.casefold() == key.casefold()), None)

    def calendar_pages(self) -> dict[int, str]:
        """The pages sync renders (everything that is not a photo or a card)."""
        return {slot: kind for slot, kind in sorted(self.pages.items()) if kind != "photo" and kind not in CARD_KINDS}

    def board_pages(self) -> dict[int, str]:
        """The message board pages (留言板 / 大字留言)."""
        return {slot: kind for slot, kind in sorted(self.pages.items()) if kind in BOARD_KINDS}


def config_dir() -> Path:
    if os.environ.get("ULANI_CONFIG_DIR"):
        return Path(os.environ["ULANI_CONFIG_DIR"])
    if sys.platform == "win32":
        return Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming") / "ulani-epaper"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "ulani-epaper"
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "ulani-epaper"


def settings_path() -> Path:
    return config_dir() / "settings.json"


def load(path: str | os.PathLike | None = None) -> Settings:
    path = Path(path or settings_path())
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return Settings()
    except (OSError, ValueError) as e:
        raise UlaniError(f"cannot read the settings file {path}: {e}") from None
    try:
        s = Settings(pages={**DEFAULT_PAGES, **{int(k): v for k, v in raw.get("pages", {}).items()}},
                     feeds=[Feed(str(f["id"]), str(f["name"]), str(f.get("color") or ""))
                            for f in raw.get("feeds") or ()],
                     times=list(raw.get("times") or DEFAULT_TIMES), address=raw.get("address"))
        s.validate()
    except (TypeError, ValueError, AttributeError, KeyError) as e:
        raise UlaniError(f"the settings file {path} is invalid: {e!r}") from None
    return s


def save(settings: Settings, path: str | os.PathLike | None = None) -> None:
    settings.validate()
    path = Path(path or settings_path())
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = asdict(settings)
    raw["pages"] = {str(k): v for k, v in sorted(settings.pages.items())}
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(raw, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
