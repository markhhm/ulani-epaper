"""Cards (牌卡): a background (a photo with a crop, or one of the 7 panel colours)
and up to 8 short text boxes, saved by the owner and drawn by layouts.render_card.
The format is shared with the other apps: see shared/CARDS.md.

Kept in the config folder (see config.config_dir()): ``cards.json`` (newest
first, written atomically like settings.json) and ``backgrounds/`` with one
``<id>.jpg`` per card that has a photo, already upright and capped at 4K by
image.open_image. Cards are the owner's own words and pictures, so keeping
them is fine (unlike calendar data, which is never stored).

A card travels between apps as one ``.paperhue-card`` zip: ``card.json`` and
the background image as ``background.jpg``.
"""

from __future__ import annotations

import io
import json
import math
import os
import re
import secrets
import tempfile
import zipfile
from dataclasses import dataclass, replace
from pathlib import Path
from typing import BinaryIO

from PIL import Image

from . import config
from . import image as im
from .notes import normalize
from .protocol import UlaniError

__all__ = ["ALIGNS", "INKS", "MAX_SIZE", "MAX_TEXT", "MAX_TEXTS", "MIN_SIZE", "Background", "Card", "TextBox", "add",
           "backgrounds_dir", "cards_path", "check", "export_card", "get", "import_card", "load", "parse", "remove",
           "save", "to_json", "update"]

VERSION = 1
MAX_TEXTS = 8  # text boxes per card
MAX_TEXT = 80  # characters per box, after normalize()
MIN_SIZE, MAX_SIZE = 12, 240  # font size in panel pixels (the panel is 480 high)
INKS = tuple(im.COLOURS)  # the 7 panel colours
ALIGNS = ("left", "center", "right")
EXTENSION = ".paperhue-card"
JPEG_QUALITY = 92
MAX_JSON_BYTES = 64 * 1024  # what an imported file may hold (it is not trusted)
MAX_IMAGE_BYTES = 40 * 1024 * 1024

_ID = re.compile(r"[0-9a-f]{8}")
_FILE = re.compile(r"[0-9A-Za-z_-]{1,40}\.(jpg|jpeg|png)")  # a plain file name, never a path
_EPS = 1e-9


@dataclass(frozen=True)
class TextBox:
    text: str  # normalized: NFC, "\n" line breaks, no outer whitespace
    box: tuple[float, float, float, float]  # x, y, width, height as fractions of the screen
    size: int = 48  # panel pixels
    color: str = "black"
    outline: bool = False
    outline_color: str = "white"
    align: str = "center"  # one of ALIGNS


@dataclass(frozen=True)
class Background:
    color: str = "white"  # used when there is no image
    image: str | None = None  # file in backgrounds/
    crop: im.Crop | None = None  # (left, top, width, height) of the photo, see shared/CROP.md


@dataclass(frozen=True)
class Card:
    id: str = ""  # 8 hex characters, unique within the file ("" until add())
    background: Background = Background()
    texts: tuple[TextBox, ...] = ()


# --- validation and JSON -------------------------------------------------------------


def _numbers(value, n: int, what: str) -> tuple[float, ...]:
    ok = (isinstance(value, (list, tuple)) and len(value) == n
          and all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in value))
    if not ok:
        raise ValueError(f"{what}要有 {n} 個數字，收到 {value!r}")
    return tuple(float(v) for v in value)


def _inside(left: float, top: float, w: float, h: float, what: str) -> None:
    if left < 0 or top < 0 or w <= 0 or h <= 0 or left + w > 1 + _EPS or top + h > 1 + _EPS:
        raise ValueError(f"{what}必須在畫面內（0 到 1 的比例），收到 {(left, top, w, h)!r}")


def _ink(value, what: str) -> str:
    if value not in INKS:
        raise ValueError(f"{what}必須是 {', '.join(INKS)} 之一，收到 {value!r}")
    return value


def _check_text(t: TextBox) -> TextBox:
    if not isinstance(t.text, str):
        raise ValueError("文字必須是字串")
    text = normalize(t.text)
    if not text:
        raise ValueError("文字框是空的")
    if len(text) > MAX_TEXT:
        raise ValueError(f"每個文字框最多 {MAX_TEXT} 字（目前 {len(text)} 字）")
    box = _numbers(t.box, 4, "文字框的位置")
    _inside(*box, "文字框")
    if not isinstance(t.size, int) or isinstance(t.size, bool) or not MIN_SIZE <= t.size <= MAX_SIZE:
        raise ValueError(f"字級必須是 {MIN_SIZE} 到 {MAX_SIZE} 的整數，收到 {t.size!r}")
    if not isinstance(t.outline, bool):
        raise ValueError("outline 必須是 true 或 false")
    if t.align not in ALIGNS:
        raise ValueError(f"對齊必須是 {', '.join(ALIGNS)} 之一，收到 {t.align!r}")
    return TextBox(text, box, t.size, _ink(t.color, "文字顏色"), t.outline, _ink(t.outline_color, "外框顏色"), t.align)


def check(card: Card) -> Card:
    """``card`` with its text normalized, or ValueError (in Traditional Chinese) if it cannot be a card.
    Its background image is only a file name here; add() and update() look at the file."""
    bg = card.background
    if bg.image is not None and (not isinstance(bg.image, str) or not _FILE.fullmatch(bg.image)):
        raise ValueError(f"背景圖必須是單純的檔名（jpg 或 png），收到 {bg.image!r}")
    crop = None
    if bg.crop is not None:  # a crop with no image yet: add() is about to be given the photo
        crop = _numbers(bg.crop, 4, "裁切範圍")
        _inside(*crop, "裁切範圍")
    background = Background(_ink(bg.color, "背景顏色"), bg.image, crop)
    if len(card.texts) > MAX_TEXTS:
        raise ValueError(f"每張牌卡最多 {MAX_TEXTS} 個文字框（目前 {len(card.texts)} 個）")
    return Card(card.id, background, tuple(_check_text(t) for t in card.texts))


def to_json(card: Card) -> dict:
    bg = card.background
    background = {"color": bg.color} if bg.image is None else {"image": bg.image, "crop": bg.crop and list(bg.crop)}
    return {"version": VERSION, "id": card.id, "background": background,
            "texts": [{"text": t.text, "box": list(t.box), "size": t.size, "color": t.color, "outline": t.outline,
                       "outline_color": t.outline_color, "align": t.align} for t in card.texts]}


def parse(obj) -> Card:
    """A card from its JSON (see shared/CARDS.md), checked; ValueError if it is not one."""
    try:
        if obj["version"] != VERSION:
            raise ValueError(f"unknown version {obj['version']!r}")
        bg = obj["background"]
        background = Background(bg.get("color", "white"), bg.get("image"),
                                None if bg.get("crop") is None else tuple(bg["crop"]))
        texts = tuple(TextBox(t["text"], tuple(t["box"]), t.get("size", 48), t.get("color", "black"),
                              t.get("outline", False), t.get("outline_color", "white"), t.get("align", "center"))
                      for t in obj["texts"])
        card = Card(obj["id"], background, texts)
    except (TypeError, AttributeError, KeyError) as e:
        raise ValueError(f"not a card: {e!r}") from None
    if not isinstance(card.id, str) or not _ID.fullmatch(card.id):
        raise ValueError(f"card ids are 8 hex characters, got {card.id!r}")
    return check(card)


# --- the store -----------------------------------------------------------------------


def _root(folder: str | os.PathLike | None) -> Path:
    return Path(folder) if folder else config.config_dir()


def cards_path(folder: str | os.PathLike | None = None) -> Path:
    return _root(folder) / "cards.json"


def backgrounds_dir(folder: str | os.PathLike | None = None) -> Path:
    return _root(folder) / "backgrounds"


def load(folder: str | os.PathLike | None = None) -> list[Card]:
    """The cards, newest first. A missing file means no cards; a file that cannot
    be read or is invalid raises UlaniError (it is never overwritten)."""
    path = cards_path(folder)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as e:
        raise UlaniError(f"cannot read the cards file {path}: {e}") from None
    try:
        if raw.get("version") != VERSION:
            raise ValueError(f"unknown version {raw.get('version')!r}")
        found = [parse(c) for c in raw["cards"]]
        if len({c.id for c in found}) != len(found):
            raise ValueError("duplicate card ids")
        return found
    except (TypeError, ValueError, AttributeError, KeyError) as e:
        raise UlaniError(f"the cards file {path} is invalid: {e!r}") from None


def save(cards: list[Card], folder: str | os.PathLike | None = None) -> None:
    ids = [c.id for c in cards]
    if len(set(ids)) != len(ids) or not all(_ID.fullmatch(i) for i in ids):
        raise ValueError(f"card ids must be 8 hex characters and unique, got {ids}")
    raw = {"version": VERSION, "cards": [to_json(check(c)) for c in cards]}
    path = cards_path(folder)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".cards-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(raw, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def get(card_id: str, folder: str | os.PathLike | None = None) -> Card:
    card = next((c for c in load(folder) if c.id == card_id), None)
    if card is None:
        raise UlaniError(f"沒有這張牌卡：{card_id}")
    return card


def _read_photo(src: str | os.PathLike | BinaryIO) -> Image.Image:
    try:
        return im.open_image(src)  # upright, at most 4K, and refuses over 50 MP
    except (OSError, SyntaxError, ValueError) as e:
        raise UlaniError(f"無法讀取背景圖：{e}") from None


def _write_photo(img: Image.Image, card_id: str, folder) -> str:
    directory = backgrounds_dir(folder)
    directory.mkdir(parents=True, exist_ok=True)
    name = f"{card_id}.jpg"
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".bg-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            im._to_rgb(img).save(f, "JPEG", quality=JPEG_QUALITY)
        os.replace(tmp, directory / name)
    except BaseException:
        os.unlink(tmp)
        raise
    return name


def _with_photo(card: Card, photo, folder, current: Card | None) -> Card:
    """``card`` (checked) with its background file in place: ``photo`` copied in as ``<id>.jpg``, or the
    file the card already has. The crop is checked against the stored photo."""
    bg = card.background
    if photo is not None:
        img = _read_photo(photo)
        crop = None if bg.crop is None else im.check_crop(bg.crop, *img.size)
        return replace(card, background=Background(image=_write_photo(img, card.id, folder), crop=crop))
    if bg.image is None:
        return replace(card, background=Background(bg.color))  # a crop means nothing without a photo
    if current is None or current.background.image != bg.image:
        raise ValueError("牌卡的背景圖要用 photo 指定")
    if bg.crop is not None:
        with Image.open(backgrounds_dir(folder) / bg.image) as stored:
            im.check_crop(bg.crop, *stored.size)
    return card


def _new_id(taken: set[str]) -> str:
    while True:
        candidate = secrets.token_hex(4)
        if candidate not in taken:
            return candidate


def add(card: Card, photo: str | os.PathLike | BinaryIO | None = None,
        folder: str | os.PathLike | None = None) -> Card:
    """Save ``card`` as a new card on top, under a new id (the one it has is ignored). ``photo`` (a file) is copied
    into the store as its background, upright and at most 4K; its ``background.crop`` then
    applies to that photo. ValueError if the card is not valid."""
    cards = load(folder)
    card = check(replace(card, id=_new_id({c.id for c in cards})))
    card = _with_photo(card, photo, folder, None)
    save([card] + cards, folder)
    return card


def update(card: Card, photo: str | os.PathLike | BinaryIO | None = None,
           folder: str | os.PathLike | None = None) -> Card:
    """Replace the saved card with the same id, in place. Without ``photo`` the background image must
    be the one the card already has (or none: then the old file is deleted)."""
    cards = load(folder)
    i = next((i for i, c in enumerate(cards) if c.id == card.id), None)
    if i is None:
        raise UlaniError(f"沒有這張牌卡：{card.id}")
    old = cards[i]
    card = _with_photo(check(card), photo, folder, old)
    cards[i] = card
    save(cards, folder)
    if old.background.image and not card.background.image:
        (backgrounds_dir(folder) / old.background.image).unlink(missing_ok=True)
    return card


def remove(card_id: str, folder: str | os.PathLike | None = None) -> Card:
    """Delete a card and its background file; returns the card."""
    cards = load(folder)
    card = get(card_id, folder)
    save([c for c in cards if c.id != card_id], folder)
    if card.background.image:
        (backgrounds_dir(folder) / card.background.image).unlink(missing_ok=True)
    return card


# --- the .paperhue-card file ----------------------------------------------------------

EXPORT_IMAGE = "background.jpg"


def export_card(card_id: str, dest: str | os.PathLike, folder: str | os.PathLike | None = None) -> Path:
    """Write the card as one ``.paperhue-card`` zip (card.json, and background.jpg when it has a photo)."""
    card = get(card_id, folder)
    source = backgrounds_dir(folder) / card.background.image if card.background.image else None
    if source is not None:
        if not source.is_file():
            raise UlaniError(f"找不到牌卡的背景圖：{source}")
        card = replace(card, background=replace(card.background, image=EXPORT_IMAGE))
    with zipfile.ZipFile(dest, "w") as z:
        z.writestr("card.json", json.dumps(to_json(card), ensure_ascii=False, indent=1),
                   compress_type=zipfile.ZIP_DEFLATED)
        if source is not None:
            z.write(source, EXPORT_IMAGE, compress_type=zipfile.ZIP_STORED)  # a JPEG does not shrink
    return Path(dest)


def _member(z: zipfile.ZipFile, name: str, limit: int) -> bytes:
    if z.getinfo(name).file_size > limit:
        raise ValueError(f"{name} 太大")
    return z.read(name)


def import_card(src: str | os.PathLike, folder: str | os.PathLike | None = None) -> Card:
    """Add the card in a ``.paperhue-card`` file as a new card (a new id, so importing twice makes two).
    UlaniError if the file is not a card file; nothing is saved then."""
    try:
        with zipfile.ZipFile(src) as z:
            card = parse(json.loads(_member(z, "card.json", MAX_JSON_BYTES)))
            photo = io.BytesIO(_member(z, card.background.image, MAX_IMAGE_BYTES)) if card.background.image else None
        return add(card, photo, folder)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as e:
        raise UlaniError(f"這不是有效的牌卡檔：{e}") from None
