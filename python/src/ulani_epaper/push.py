"""One-call API for apps: put up to four images onto the device's pages.

    import asyncio
    from ulani_epaper.push import push_images

    asyncio.run(push_images(["a.jpg", "b.jpg", "c.jpg", "d.jpg"]))
"""

from __future__ import annotations

import os
from typing import Callable, Mapping, Sequence, Union

from PIL import Image

from . import image
from .client import PushEvent, UploadResult, connect
from .image import Fit
from .protocol import USER_SLOTS

__all__ = ["ImageSource", "prepare", "push_frames", "push_images"]

#: A file path or an already opened PIL image.
ImageSource = Union[str, "os.PathLike[str]", Image.Image]


def _as_mapping(images: Mapping[int, ImageSource | None] | Sequence[ImageSource | None]) -> dict[int, ImageSource]:
    if isinstance(images, (str, os.PathLike, Image.Image)):
        images = [images]  # one image: page 1 (a str is not a sequence of paths)
    if isinstance(images, Mapping):
        mapping = dict(images)
    else:
        images = list(images)
        if len(images) > len(USER_SLOTS):
            raise ValueError(f"at most {len(USER_SLOTS)} images (one per page), got {len(images)}")
        mapping = dict(zip(USER_SLOTS, images))
    mapping = {slot: src for slot, src in mapping.items() if src is not None}
    bad = [slot for slot in mapping if slot not in USER_SLOTS]
    if bad:
        raise ValueError(f"pages are 1-4, got {bad}")
    if not mapping:
        raise ValueError("no images given")
    return mapping


def prepare(images: Mapping[int, ImageSource | None] | Sequence[ImageSource | None],
            fit: Fit = "cover", dither: bool = True,
            crops: Mapping[int, image.Crop] | None = None) -> dict[int, bytes]:
    """Encode images into raw frames ``{page: frame}``.

    ``images`` is either a sequence (item *n* goes to page *n + 1*; ``None``
    leaves that page alone) or a mapping ``{page: image}``. Photos default to
    ``cover``: fill the whole panel, cropping what does not fit; ``crops``
    chooses the part of a page's photo to show (see image.check_crop).
    """
    crops = dict(crops or {})
    frames = {}
    for slot, src in _as_mapping(images).items():
        if isinstance(src, Image.Image):
            frames[slot] = image.encode(src, fit_mode=fit, dither=dither, crop=crops.get(slot))
        else:
            with image.open_image(src) as img:
                frames[slot] = image.encode(img, fit_mode=fit, dither=dither, crop=crops.get(slot))
    return frames


async def push_images(images: Mapping[int, ImageSource | None] | Sequence[ImageSource | None], *,
                      fit: Fit = "cover", dither: bool = True, address: str | None = None,
                      progress: Callable[[PushEvent], None] | None = None,
                      **connect_kwargs) -> dict[int, UploadResult]:
    """Encode up to four images and upload them in one connection.

    The page currently on screen is uploaded last so the panel refreshes only
    once (~40 s, at the end). ``progress`` receives :class:`PushEvent` objects.
    Extra keyword arguments go to :func:`ulani_epaper.client.connect`.
    """
    return await push_frames(prepare(images, fit=fit, dither=dither), address=address,
                             progress=progress, **connect_kwargs)


async def push_frames(frames: Mapping[int, bytes], *, address: str | None = None,
                      progress: Callable[[PushEvent], None] | None = None, show: int | None = None,
                      **connect_kwargs) -> dict[int, UploadResult]:
    """Upload already encoded frames ``{page: frame}`` (see :func:`prepare`).

    ``show`` (1-4) also switches the display to that page in the same
    connection, with a single panel refresh (see ``Calendar.push_pages``).
    """
    async with connect(address, **connect_kwargs) as cal:
        return await cal.push_pages(frames, progress=progress, show=show)
