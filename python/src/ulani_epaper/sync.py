"""Fetch the calendar feeds, draw the calendar pages and push them; post the message board; push cards;
push every page at once (``push_all``, the desktop app's push).

Everything fetched or drawn stays in memory: nothing from the feeds is written
to disk. A scheduled sync redraws only the calendar pages: the message board
pages change when a note is posted (``post``) and the card pages when a card is
pushed (``push_card``, ``preload_cards``), or with ``push_all``. The board pages are drawn from the
owner's saved notes (notes.py) and need no network. Whether a page needs
sending is decided by the device itself (a page that already holds the same
image is skipped by the upload probe); the only local record is which card
this app last put on each card page (``Settings.card_pages``).
"""

from __future__ import annotations

import asyncio
import hashlib
from dataclasses import dataclass, field
from datetime import date, datetime, tzinfo
from typing import Callable, Literal, Mapping, Sequence

from PIL import Image

from . import config, feeds, image, layouts
from . import cards as card_store
from . import notes as note_store
from .notes import Note
from .agenda import LOCAL
from .cards import Card
from .client import PushEvent, UploadResult, connect
from .protocol import UlaniError
from .push import push_frames
from .strings import t

#: calendar kinds (month / agenda / todo / day / monthgrid): render(data, today, tz), or
#: render(data, today, tz, background) when the page has a background photo (layouts.load_background)
Renderer = Callable[..., Image.Image]
#: board kinds (board / message): render(notes newest first, tz)
BoardRenderer = Callable[[Sequence[Note], tzinfo], Image.Image]
Show = Literal["auto", "board", "message", "none"]

NO_BOARD_PAGE = "沒有留言頁：先把某一頁設為「留言板」或「大字留言」"
NO_CARD_PAGE = "沒有牌卡頁：先把某一頁設為「牌卡」"


class NoCardPage(UlaniError):
    """No page is set to 牌卡. An app can turn this into a one-tap offer to make ``suggested_slot`` one:
    the lowest-numbered photo page, else page 4."""

    def __init__(self, suggested_slot: int):
        super().__init__(NO_CARD_PAGE)
        self.suggested_slot = suggested_slot


_PALETTE = {c.rgb for c in image.PALETTE}


def default_renderers() -> dict[str, Renderer | BoardRenderer]:
    return {"month": layouts.render_month, "agenda": layouts.render_agenda, "todo": layouts.render_todo,
            "day": layouts.render_day, "monthgrid": layouts.render_monthgrid, "board": layouts.render_board, "message": layouts.render_message}


@dataclass
class SyncReport:
    pages: dict[int, str] = field(default_factory=dict)  # page -> kind that was drawn
    events: int = 0
    tasks: int = 0
    images: dict[int, Image.Image] = field(default_factory=dict)  # in memory only (previews)
    results: dict[int, UploadResult] | None = None  # None: nothing was pushed
    notes: int = 0  # notes the board pages were drawn from
    show: int | None = None  # page the display was switched to (post); a dry run only names it
    warnings: list[str] = field(default_factory=list)  # something was left out, the sync still went through


def _check_palette(slot: int, img: Image.Image) -> None:
    colours = img.convert("RGB").getcolors(1 << 24)
    stray = {rgb for _, rgb in colours} - _PALETTE
    if img.size != (image.WIDTH, image.HEIGHT) or stray:
        raise ValueError(f"page {slot}: renderer drew {img.size} with colours outside the palette "
                         f"{sorted(stray)[:5]}")


def _draw(report: SyncReport, pages: Mapping[int, str], renderers: Mapping[str, Callable[..., Image.Image]],
          args: Callable[[str], tuple], backgrounds: Mapping[int, Image.Image] | None = None) -> dict[int, bytes]:
    frames = {}
    for slot, kind in pages.items():
        img = renderers[kind](*args(kind), *([backgrounds[slot]] if backgrounds and slot in backgrounds else []))
        _check_palette(slot, img)
        report.images[slot] = img
        frames[slot] = image.encode(img, dither=False)
    return frames


async def sync(settings: config.Settings | None = None, *, now: datetime | None = None,
               secrets: feeds.SecretStore | None = None, download: Callable[..., bytes] | None = None,
               renderers: Mapping[str, Renderer | BoardRenderer] | None = None, push=push_frames,
               dry_run: bool = False, progress: Callable[[PushEvent], None] | None = None,
               on_rendered: Callable[[dict[int, Image.Image]], None] | None = None,
               **connect_kwargs) -> SyncReport:
    """One sync: feeds -> calendar pages -> device. Redraws only the calendar pages (month / agenda / todo /
    day / monthgrid), never a card, photo or board page; with no feeds set up the public Taiwan holidays
    are the calendar (see feeds.fetch). Raises before pushing anything if fetching or drawing
    fails, so the device never gets half an update. ``on_rendered`` receives
    the drawings before the push starts (previews)."""
    settings = settings or config.load()
    pages = settings.calendar_pages()
    report = SyncReport()
    if not pages:
        return report
    now = now or datetime.now(LOCAL)
    tz = now.tzinfo or LOCAL
    today = now.date()
    data = await asyncio.to_thread(feeds.fetch, settings.feeds, today, tz, now, secrets, download)
    report.events, report.tasks = len(data.events), len(data.tasks)
    renderers = {**default_renderers(), **(renderers or {})}
    report.pages = dict(pages)
    frames = _draw(report, pages, renderers, lambda kind: (data, today, tz), _backgrounds(settings, pages, report))
    if on_rendered:
        on_rendered(dict(report.images))
    if not dry_run:
        report.results = await push(frames, address=settings.address, progress=progress, **connect_kwargs)
    return report


def _backgrounds(settings: config.Settings, pages: Mapping[int, str], report: SyncReport) -> dict[int, Image.Image]:
    """The background photos of ``pages``, ready to draw on."""
    backgrounds = {}
    for slot, bg in settings.backgrounds.items():
        if slot not in pages:
            continue
        try:  # a few seconds each: only the pages that have one
            backgrounds[slot] = layouts.load_background(bg.image, bg.crop, strength=settings.grain,
                                                        colours=settings.colours)
        except UlaniError as e:  # one lost photo must not stop every sync: draw that page as without one
            report.warnings.append(t("sync_bg_unreadable", slot=slot, image=bg.image, error=e))
    return backgrounds


def show_target(board_pages: Mapping[int, str], show: str) -> int | None:
    """The page ``post`` switches the display to. "auto": the first 大字留言
    page, else the first 留言板 page; "board" / "message": the first page of
    that kind (the "auto" choice when there is none); "none": no switch."""
    if show not in ("auto", "board", "message", "none"):
        raise ValueError(f"show must be auto, board, message or none, got {show!r}")
    if show == "none":
        return None
    for kind in ((show,) if show != "auto" else ()) + ("message", "board"):
        slot = next((s for s, k in sorted(board_pages.items()) if k == kind), None)
        if slot is not None:
            return slot
    return None


async def post(settings: config.Settings | None = None, *, show: Show = "auto", push=push_frames,
               progress: Callable[[PushEvent], None] | None = None, dry_run: bool = False,
               notes: Sequence[Note] | None = None, tz: tzinfo | None = None,
               renderers: Mapping[str, BoardRenderer] | None = None,
               on_rendered: Callable[[dict[int, Image.Image]], None] | None = None,
               **connect_kwargs) -> SyncReport:
    """Draw only the message board pages (留言板 / 大字留言) from the saved
    notes (or ``notes``, newest first), push them and switch the display (see
    :func:`show_target`), all in one connection. No feeds are downloaded,
    so it works offline. UlaniError when no page is a board kind."""
    settings = settings or config.load()
    pages = settings.board_pages()
    if not pages:
        raise UlaniError(NO_BOARD_PAGE)
    target = show_target(pages, show)
    board = list(notes if notes is not None else note_store.load())
    tz = tz or LOCAL
    renderers = {**default_renderers(), **(renderers or {})}
    report = SyncReport(pages=dict(pages), notes=len(board), show=target)
    frames = _draw(report, pages, renderers, lambda kind: (board, tz))
    if on_rendered:
        on_rendered(dict(report.images))
    if not dry_run:
        report.results = await push(frames, address=settings.address, progress=progress, show=target,
                                    **connect_kwargs)
    return report


# --- cards ---------------------------------------------------------------------------


def frame_hash(frame: bytes) -> str:
    """What ``Settings.card_pages`` keeps for a card page: a fingerprint of the image it was last given."""
    return hashlib.sha256(frame).hexdigest()[:16]


def _no_card_page(settings: config.Settings) -> NoCardPage:
    return NoCardPage(next((slot for slot, kind in sorted(settings.pages.items()) if kind == "photo"), 4))


def _draw_card(card: Card, settings: config.Settings) -> tuple[Image.Image, bytes]:
    """The card drawn with the settings' grain and colours, and its frame."""
    img = layouts.render_card(card, strength=settings.grain, colours=settings.colours)  # a photo: a few seconds
    return img, image.encode(img, dither=False)


def _remember(settings: config.Settings, slots: Sequence[int], frames: Mapping[int, bytes]) -> None:
    """Record what this app put on the card pages; a page that is no longer a card page is forgotten."""
    kept = {slot: mark for slot, mark in settings.card_pages.items() if slot in slots}
    settings.card_pages = {**kept, **{slot: frame_hash(frame) for slot, frame in frames.items()}}


def card_slot(slots: Sequence[int], preloaded: Sequence[int], shown: int) -> int:
    """The card page a pushed card goes to: the page it is already on (the one on screen if it is on
    several), else the card page on screen, else the lowest-numbered card page."""
    if shown in preloaded or not preloaded and shown in slots:
        return shown
    return preloaded[0] if preloaded else slots[0]


async def push_card(settings: config.Settings, card: Card, *, connect=connect,
                    progress: Callable[[PushEvent], None] | None = None, **connect_kwargs) -> SyncReport:
    """Show ``card`` on the device, in one connection: upload it to the page chosen by :func:`card_slot`
    (the device skips an image it already holds, so a preloaded card only switches the display) and switch
    to that page. ``NoCardPage`` when no page is a card page. ``settings.card_pages`` is updated; saving
    the settings is up to the caller."""
    slots = settings.card_page_slots()
    if not slots:
        raise _no_card_page(settings)
    img, frame = _draw_card(card, settings)
    preloaded = [slot for slot in slots if settings.card_pages.get(slot) == frame_hash(frame)]
    async with connect(settings.address, **connect_kwargs) as cal:
        shown, _ = await cal.current_slot()
        slot = card_slot(slots, preloaded, shown)
        results = await cal.push_pages({slot: frame}, progress=progress, show=slot)
    _remember(settings, slots, {slot: frame})
    return SyncReport(pages={slot: "card"}, images={slot: img}, results=results, show=slot)


async def preload_cards(settings: config.Settings, cards: Sequence[Card], *, connect=connect,
                        progress: Callable[[PushEvent], None] | None = None, **connect_kwargs) -> SyncReport:
    """Put ``cards`` on the card pages (the first on the lowest-numbered one, and so on) in one connection,
    without switching the display. Only the pages whose image differs are uploaded: the device skips the
    others. ``NoCardPage`` when no page is a card page; UlaniError, before connecting, when there are more
    cards than card pages."""
    slots = settings.card_page_slots()
    if not slots:
        raise _no_card_page(settings)
    if len(cards) > len(slots):
        raise UlaniError(f"{len(cards)} 張牌卡放不進 {len(slots)} 個牌卡頁")
    drawn = {slot: _draw_card(card, settings) for slot, card in zip(slots, cards)}
    frames = {slot: frame for slot, (_, frame) in drawn.items()}
    async with connect(settings.address, **connect_kwargs) as cal:
        results = await cal.push_pages(frames, progress=progress)
    _remember(settings, slots, frames)
    return SyncReport(pages={slot: "card" for slot in frames}, images={slot: img for slot, (img, _) in drawn.items()},
                      results=results)


# --- the desktop app's push ----------------------------------------------------------


async def push_all(settings: config.Settings, photos: Mapping[int, bytes], *, only: int | None = None,
                   now: datetime | None = None, secrets: feeds.SecretStore | None = None,
                   download: Callable[..., bytes] | None = None,
                   renderers: Mapping[str, Renderer | BoardRenderer] | None = None,
                   notes: Sequence[Note] | None = None, push=push_frames,
                   progress: Callable[[PushEvent], None] | None = None,
                   on_rendered: Callable[[dict[int, Image.Image]], None] | None = None,
                   **connect_kwargs) -> SyncReport:
    """Every page that has something to send, in one connection, without switching the display: the photo
    pages in ``photos`` (already encoded), the calendar pages (fetched and drawn as :func:`sync` does), the
    message board pages (from the saved notes, or ``notes``) and the card pages with a card in
    ``settings.card_choice``. ``only``: that page alone. When the calendars cannot be read, the calendar pages
    are left out with a warning and the rest still goes (with ``only`` the error is raised). The device skips
    a page that already holds the same image; nothing is pushed when there is nothing to send.
    ``settings.card_pages`` is updated as :func:`push_card` does; saving the settings is up to the caller."""
    scope = {slot: kind for slot, kind in sorted(settings.pages.items()) if only in (None, slot)}
    report = SyncReport(pages={slot: kind for slot, kind in scope.items() if kind == "photo" and slot in photos})
    frames = {slot: photos[slot] for slot in report.pages}
    renderers = {**default_renderers(), **(renderers or {})}
    now = now or datetime.now(LOCAL)
    tz = now.tzinfo or LOCAL
    calendar = {slot: kind for slot, kind in scope.items() if kind in config.CALENDAR_KINDS}
    if calendar:
        try:
            data = await asyncio.to_thread(feeds.fetch, settings.feeds, now.date(), tz, now, secrets, download)
        except (UlaniError, ImportError) as e:  # offline, a source that fails, or no calendar packages
            if only is not None:
                raise
            report.warnings.append(t("push_no_calendars", error=e))
        else:
            report.events, report.tasks = len(data.events), len(data.tasks)
            report.pages.update(calendar)
            frames.update(_draw(report, calendar, renderers, lambda kind: (data, now.date(), tz),
                                _backgrounds(settings, calendar, report)))
    boards = {slot: kind for slot, kind in scope.items() if kind in config.BOARD_KINDS}
    if boards:
        board = list(notes if notes is not None else note_store.load())
        report.notes = len(board)
        report.pages.update(boards)
        frames.update(_draw(report, boards, renderers, lambda kind: (board, tz)))
    chosen = {slot: settings.card_choice[slot] for slot, kind in scope.items()
              if kind in config.CARD_KINDS and slot in settings.card_choice}
    saved = {card.id: card for card in card_store.load()} if chosen else {}
    for slot, card_id in chosen.items():
        if card_id in saved:  # a deleted card leaves its page as it is
            report.images[slot], frames[slot] = _draw_card(saved[card_id], settings)
            report.pages[slot] = "card"
    if on_rendered:
        on_rendered(dict(report.images))
    if frames:
        report.results = await push(frames, address=settings.address, progress=progress, **connect_kwargs)
        _remember(settings, settings.card_page_slots(),
                  {slot: frame for slot, frame in frames.items() if report.pages[slot] == "card"})
    return report
