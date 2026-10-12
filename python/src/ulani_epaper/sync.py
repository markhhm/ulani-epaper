"""Fetch the calendar feeds, draw the calendar and message board pages, push them.

Everything fetched or drawn stays in memory: nothing from the feeds is written
to disk. The message board pages are drawn from the owner's saved notes
(notes.py) and need no network. Whether a page needs sending is decided by
the device itself (a page that already holds the same image is skipped by the
upload probe), so there is no local state either.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import date, datetime, tzinfo
from typing import Callable, Literal, Mapping, Sequence

from PIL import Image

from . import config, feeds, image
from . import notes as note_store
from .notes import Note
from .agenda import LOCAL, AgendaData
from .client import PushEvent, UploadResult
from .protocol import UlaniError
from .push import push_frames

#: calendar kinds (month / agenda / todo): render(data, today, tz)
Renderer = Callable[[AgendaData, date, tzinfo], Image.Image]
#: board kinds (board / message): render(notes newest first, tz)
BoardRenderer = Callable[[Sequence[Note], tzinfo], Image.Image]
Show = Literal["auto", "board", "message", "none"]

NO_BOARD_PAGE = "沒有留言頁：先把某一頁設為「留言板」或「大字留言」"

_PALETTE = {c.rgb for c in image.PALETTE}


def default_renderers() -> dict[str, Renderer | BoardRenderer]:
    from . import layouts

    return {"month": layouts.render_month, "agenda": layouts.render_agenda, "todo": layouts.render_todo,
            "board": layouts.render_board, "message": layouts.render_message}


@dataclass
class SyncReport:
    pages: dict[int, str] = field(default_factory=dict)  # page -> kind that was drawn
    events: int = 0
    tasks: int = 0
    images: dict[int, Image.Image] = field(default_factory=dict)  # in memory only (previews)
    results: dict[int, UploadResult] | None = None  # None: nothing was pushed
    notes: int = 0  # notes the board pages were drawn from
    show: int | None = None  # page the display was switched to (post); a dry run only names it


def _check_palette(slot: int, img: Image.Image) -> None:
    colours = img.convert("RGB").getcolors(1 << 24)
    stray = {rgb for _, rgb in colours} - _PALETTE
    if img.size != (image.WIDTH, image.HEIGHT) or stray:
        raise ValueError(f"page {slot}: renderer drew {img.size} with colours outside the palette "
                         f"{sorted(stray)[:5]}")


def _draw(report: SyncReport, pages: Mapping[int, str], renderers: Mapping[str, Callable[..., Image.Image]],
          args: Callable[[str], tuple]) -> dict[int, bytes]:
    frames = {}
    for slot, kind in pages.items():
        img = renderers[kind](*args(kind))
        _check_palette(slot, img)
        report.images[slot] = img
        frames[slot] = image.encode(img, dither=False)
    return frames


async def sync(settings: config.Settings | None = None, *, now: datetime | None = None,
               secrets: feeds.SecretStore | None = None, download: Callable[..., bytes] | None = None,
               renderers: Mapping[str, Renderer | BoardRenderer] | None = None, push=push_frames,
               dry_run: bool = False, progress: Callable[[PushEvent], None] | None = None,
               on_rendered: Callable[[dict[int, Image.Image]], None] | None = None,
               notes: Sequence[Note] | None = None, **connect_kwargs) -> SyncReport:
    """One sync: feeds and notes -> pages -> device. Draws every page that is
    not a photo. The feeds are fetched only when a calendar page (month /
    agenda / todo) exists; board pages come from the saved notes (or
    ``notes``, newest first). Raises before pushing anything if fetching or drawing
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
    board = [] if not settings.board_pages() else list(notes if notes is not None else note_store.load())
    data = AgendaData()
    if any(kind in config.CALENDAR_KINDS for kind in pages.values()):
        data = await asyncio.to_thread(feeds.fetch, settings.feeds, today, tz, now, secrets, download)
        report.events, report.tasks = len(data.events), len(data.tasks)
    renderers = {**default_renderers(), **(renderers or {})}
    report.pages, report.notes = dict(pages), len(board)
    frames = _draw(report, pages, renderers,
                   lambda kind: (board, tz) if kind in config.BOARD_KINDS else (data, today, tz))
    if on_rendered:
        on_rendered(dict(report.images))
    if not dry_run:
        report.results = await push(frames, address=settings.address, progress=progress, **connect_kwargs)
    return report


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
