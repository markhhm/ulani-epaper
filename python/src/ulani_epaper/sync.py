"""Fetch the calendar feeds, draw the calendar pages, push them.

Everything happens in memory: nothing fetched or drawn is written to disk.
Whether a page needs sending is decided by the device itself (a page that
already holds the same image is skipped by the upload probe), so there is
no local state either.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import date, datetime, tzinfo
from typing import Callable, Mapping

from PIL import Image

from . import config, feeds, image
from .agenda import LOCAL, AgendaData
from .client import PushEvent, UploadResult
from .push import push_frames

Renderer = Callable[[AgendaData, date, tzinfo], Image.Image]

_PALETTE = {c.rgb for c in image.PALETTE}


def default_renderers() -> dict[str, Renderer]:
    from . import layouts

    return {"month": layouts.render_month, "agenda": layouts.render_agenda, "todo": layouts.render_todo}


@dataclass
class SyncReport:
    pages: dict[int, str] = field(default_factory=dict)  # page -> kind that was drawn
    events: int = 0
    tasks: int = 0
    images: dict[int, Image.Image] = field(default_factory=dict)  # in memory only (previews)
    results: dict[int, UploadResult] | None = None  # None: nothing was pushed


def _check_palette(slot: int, img: Image.Image) -> None:
    colours = img.convert("RGB").getcolors(1 << 24)
    stray = {rgb for _, rgb in colours} - _PALETTE
    if img.size != (image.WIDTH, image.HEIGHT) or stray:
        raise ValueError(f"page {slot}: renderer drew {img.size} with colours outside the palette "
                         f"{sorted(stray)[:5]}")


async def sync(settings: config.Settings | None = None, *, now: datetime | None = None,
               secrets: feeds.SecretStore | None = None, download: Callable[..., bytes] | None = None,
               renderers: Mapping[str, Renderer] | None = None, push=push_frames, dry_run: bool = False,
               progress: Callable[[PushEvent], None] | None = None,
               on_rendered: Callable[[dict[int, Image.Image]], None] | None = None,
               **connect_kwargs) -> SyncReport:
    """One sync: feeds -> pages -> device. Raises before pushing anything
    if fetching or drawing fails, so the device never gets half an update.
    ``on_rendered`` receives the drawings before the push starts (previews)."""
    settings = settings or config.load()
    pages = settings.calendar_pages()
    report = SyncReport()
    if not pages:
        return report
    now = now or datetime.now(LOCAL)
    tz = now.tzinfo or LOCAL
    today = now.date()
    data = await asyncio.to_thread(feeds.fetch, settings.feeds, today, tz, now, secrets, download)
    renderers = renderers or default_renderers()
    report.pages, report.events, report.tasks = dict(pages), len(data.events), len(data.tasks)
    frames = {}
    for slot, kind in pages.items():
        img = renderers[kind](data, today, tz)
        _check_palette(slot, img)
        report.images[slot] = img
        frames[slot] = image.encode(img, dither=False)
    if on_rendered:
        on_rendered(dict(report.images))
    if not dry_run:
        report.results = await push(frames, address=settings.address, progress=progress, **connect_kwargs)
    return report
