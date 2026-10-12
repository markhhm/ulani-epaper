"""Settings for the calendar pages: what each page shows, which calendar
feeds (by id, name and colour; their addresses are secrets kept in the OS
credential store by feeds.py), when to sync. They hold no calendar content
(that is never stored).

A calendar page may sit on the owner's own photo (``Settings.backgrounds``): the
photo is copied into ``backgrounds/`` in the config folder, the setting names the
file and the crop (shared/CROP.md).

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

from . import image
from .protocol import USER_SLOTS, UlaniError
from .strings import LANGUAGES, STRINGS

PAGE_KINDS = ("photo", "month", "agenda", "todo", "day", "monthgrid", "board", "message", "card")
PAGE_NAMES = {kind: STRINGS[f"page_{kind}"]["zh"] for kind in PAGE_KINDS}  # the CLI's names; the app's: strings.page_name
CALENDAR_KINDS = ("month", "agenda", "todo", "day", "monthgrid")  # drawn from the calendar feeds
BOARD_KINDS = ("board", "message")  # drawn from the notes (notes.py), no network needed
CARD_KINDS = ("card",)  # shows a saved card (cards.py), pushed on request; sync never redraws it
DEFAULT_PAGES = {1: "month", 2: "agenda", 3: "todo", 4: "photo"}
DEFAULT_TIMES: list[str] = []  # no scheduled sync until the user picks at least one time
#: feed colours: a panel colour name, "#rrggbb", or "" (chosen automatically)
FEED_COLOURS = ("red", "orange", "yellow", "green", "blue", "black")


@dataclass
class Feed:
    """One calendar source. Its .ics address lives in the credential store under ``id``."""

    id: str
    name: str  # shown on the pages ("個人", "學校")
    color: str = ""


@dataclass(frozen=True)
class PageBackground:
    """The photo behind a calendar page: a file in ``backgrounds/`` and the part of it that is shown."""

    image: str
    crop: image.Crop | None = None  # (left, top, width, height) of the photo; None = centred


@dataclass
class Settings:
    #: page (1-4) -> one of PAGE_KINDS; "photo" and "card" pages are left alone by sync
    pages: dict[int, str] = field(default_factory=lambda: dict(DEFAULT_PAGES))
    #: calendar sources (.ics addresses), in display order
    feeds: list[Feed] = field(default_factory=list)
    #: daily sync times, "HH:MM" local time; none = no scheduled sync
    times: list[str] = field(default_factory=lambda: list(DEFAULT_TIMES))
    #: the interface language ("zh" or "en"); None = follow the system
    language: str | None = None
    #: the device's Bluetooth address; None = find it by name
    address: str | None = None
    #: page (1-4) -> the photo calendar pages are drawn on (see set_background)
    backgrounds: dict[int, PageBackground] = field(default_factory=dict)
    #: card page (1-4) -> fingerprint of the card last pushed there (see sync.push_card); only this app's own record
    card_pages: dict[int, str] = field(default_factory=dict)
    #: share of the dithering error that is spread (image.GRAIN): the "grain" setting; 1.0 = full Stucki.
    #: Used for calendar backgrounds and cards, also by the scheduled sync
    grain: float = 1.0

    def validate(self) -> None:
        for slot, kind in self.pages.items():
            if slot not in USER_SLOTS:
                raise ValueError(f"pages are 1-4, got {slot}")
            if kind not in PAGE_KINDS:
                raise ValueError(f"page {slot}: unknown kind {kind!r} (one of {', '.join(PAGE_KINDS)})")
        for slot, bg in self.backgrounds.items():
            if slot not in USER_SLOTS:
                raise ValueError(f"backgrounds are for pages 1-4, got {slot}")
            if not re.fullmatch(r"[0-9A-Za-z_-]{1,40}\.(jpg|jpeg|png)", bg.image):
                raise ValueError(f"page {slot}: the background must be a plain .jpg or .png file name, got {bg.image!r}")
            if bg.crop is not None and len(bg.crop) != 4:
                raise ValueError(f"page {slot}: a crop is four numbers, got {bg.crop!r}")
        for slot, mark in self.card_pages.items():
            if slot not in USER_SLOTS or not isinstance(mark, str):
                raise ValueError(f"card pages are 1-4 with a text fingerprint, got {slot}: {mark!r}")
        if isinstance(self.grain, bool) or not isinstance(self.grain, (int, float)) or not 0 < self.grain <= 1:
            raise ValueError(f"grain is a number above 0 and up to 1, got {self.grain!r}")
        ids = [f.id for f in self.feeds]
        if len(set(ids)) != len(ids) or not all(re.fullmatch(r"[0-9A-Za-z_-]{1,40}", i) for i in ids):
            raise ValueError(f"feed ids must be unique and simple, got {ids}")
        for f in self.feeds:
            if not f.name.strip():
                raise ValueError("every feed needs a name")
            if f.color and f.color not in FEED_COLOURS and not re.fullmatch(r"#[0-9a-fA-F]{6}", f.color):
                raise ValueError(f"feed {f.name}: colour must be one of {', '.join(FEED_COLOURS)} or #rrggbb")
        if self.language not in (None, *LANGUAGES):
            raise ValueError(f"language must be one of {', '.join(LANGUAGES)}, got {self.language!r}")
        for t in self.times:
            m = re.fullmatch(r"([0-9]{2}):([0-9]{2})", t)  # not \d: it also matches full-width digits
            if not m or int(m[1]) > 23 or int(m[2]) > 59:
                raise ValueError(f"sync times are HH:MM, got {t!r}")
        self.times = sorted(set(self.times))

    def feed(self, key: str) -> Feed | None:
        """A feed by id or (case-insensitive) name."""
        return next((f for f in self.feeds if key in (f.id,) or f.name.casefold() == key.casefold()), None)

    def calendar_pages(self) -> dict[int, str]:
        """The pages sync redraws: calendar kinds only. Photo, card and board pages change only when
        the owner pushes or posts something to them."""
        return {slot: kind for slot, kind in sorted(self.pages.items()) if kind in CALENDAR_KINDS}

    def card_page_slots(self) -> list[int]:
        """The card pages, lowest number first."""
        return [slot for slot, kind in sorted(self.pages.items()) if kind in CARD_KINDS]

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


def backgrounds_dir() -> Path:
    return config_dir() / "backgrounds"


def set_background(settings: Settings, slot: int, photo: str | os.PathLike,
                   crop: image.Crop | None = None) -> PageBackground:
    """Put ``photo`` behind the calendar page ``slot``: a copy (upright, at most 4K, as for photo pages)
    goes into ``backgrounds/page-N.jpg``, and the setting (not saved here) names it. ValueError for a bad
    crop, UlaniError for a photo that cannot be read; nothing changes then."""
    try:
        img = image.open_image(photo)
    except (OSError, SyntaxError) as e:
        raise UlaniError(f"無法讀取背景圖：{e}") from None
    crop = None if crop is None else image.check_crop(crop, *img.size)
    bg = PageBackground(f"page-{slot}.jpg", crop)
    candidate = {**settings.backgrounds, slot: bg}
    Settings(backgrounds=candidate).validate()
    directory = backgrounds_dir()
    directory.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".bg-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            image._to_rgb(img).save(f, "JPEG", quality=92)
        os.replace(tmp, directory / bg.image)
    except BaseException:
        os.unlink(tmp)
        raise
    settings.backgrounds = candidate
    return bg


def clear_background(settings: Settings, slot: int) -> None:
    """Remove the photo behind page ``slot`` (and its copy)."""
    bg = settings.backgrounds.pop(slot, None)
    if bg is not None:
        (backgrounds_dir() / bg.image).unlink(missing_ok=True)


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
                     times=list(raw.get("times") or DEFAULT_TIMES), address=raw.get("address"),
                     backgrounds={int(k): PageBackground(str(b["image"]), None if b.get("crop") is None
                                                         else tuple(float(v) for v in b["crop"]))
                                  for k, b in (raw.get("backgrounds") or {}).items()},
                     card_pages={int(k): v for k, v in (raw.get("card_pages") or {}).items()},
                     grain=raw.get("grain", 1.0),
                     language=raw.get("language") if raw.get("language") in LANGUAGES else None)
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
    raw["backgrounds"] = {str(k): {"image": b.image, "crop": None if b.crop is None else list(b.crop)}
                          for k, b in sorted(settings.backgrounds.items())}
    raw["card_pages"] = {str(k): v for k, v in sorted(settings.card_pages.items())}
    if raw["language"] is None:
        del raw["language"]  # absent = follow the system
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(raw, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
