"""Turn ordinary images into the device's 4-bit, 7-colour frame format."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Literal

from PIL import Image, ImageDraw, ImageFont, ImageOps

from .protocol import HEIGHT, WIDTH, UlaniError

Fit = Literal["contain", "cover", "stretch"]


@dataclass(frozen=True)
class PaletteColour:
    index: int
    name: str
    rgb: tuple[int, int, int]


#: Device colour indices, in the order the firmware expects them.
PALETTE = (
    PaletteColour(0, "black", (0, 0, 0)),
    PaletteColour(1, "white", (255, 255, 255)),
    PaletteColour(2, "green", (0, 255, 0)),
    PaletteColour(3, "blue", (0, 0, 255)),
    PaletteColour(4, "red", (255, 0, 0)),
    PaletteColour(5, "yellow", (255, 255, 0)),
    PaletteColour(6, "orange", (255, 125, 0)),
)
COLOURS = {c.name: c for c in PALETTE}
_FLAT_PALETTE = [v for c in PALETTE for v in c.rgb]


#: Pixel cap the apps (CLI, desktop app) allow for photos the user picked.
#: Pillow refuses more than ~179 MP by default; phones shoot 200 MP. Library
#: code never changes Image.MAX_IMAGE_PIXELS (it is process-global).
MAX_PHOTO_PIXELS = 400_000_000


def open_image(path) -> Image.Image:
    """Open an image file for the panel.

    JPEGs are decoded at reduced size (>= 2x the panel in both directions,
    which still leaves enough pixels after EXIF rotation), so a 200 MP photo
    costs tens of MB instead of gigabytes. An image above Pillow's pixel cap
    raises UlaniError instead of DecompressionBombError.
    """
    try:
        img = Image.open(path)
    except Image.DecompressionBombError as e:
        raise UlaniError(f"{os.path.basename(str(path))}: image too large ({e})") from None
    img.draft(None, (2 * WIDTH, 2 * HEIGHT))  # no-op for formats other than JPEG
    return img


def _palette_image() -> Image.Image:
    pal = Image.new("P", (1, 1))
    pal.putpalette(_FLAT_PALETTE)
    return pal


def _to_rgb(img: Image.Image) -> Image.Image:
    img = ImageOps.exif_transpose(img)
    if img.mode == "I" or img.mode.startswith("I;16"):
        # Pillow clips 32/16-bit values to 0-255 instead of scaling them.
        key = img.info.get("transparency")
        img = img.convert("I")  # getextrema() rejects I;16B / I;16L / I;16N
        scale = 257 if img.getextrema()[1] > 255 else 1

        def to_8bit(im: Image.Image) -> Image.Image:
            return im.point(lambda v: v / scale).convert("L")

        img = to_8bit(img)
        if isinstance(key, int):  # PNG tRNS grey key, in the original units:
            # map it exactly like the pixels so the two still compare equal
            img.info["transparency"] = to_8bit(Image.new("I", (1, 1), key)).getpixel((0, 0))
    if img.has_transparency_data:  # alpha channel, PA, or a PNG tRNS colour key
        rgba = img.convert("RGBA")
        bg = Image.new("RGB", rgba.size, "white")
        bg.paste(rgba, mask=rgba.getchannel("A"))
        return bg
    return img.convert("RGB")


def fit(img: Image.Image, mode: Fit = "contain", size: tuple[int, int] = (WIDTH, HEIGHT)) -> Image.Image:
    """Resize to the panel. ``contain`` letterboxes on white, ``cover`` crops."""
    img = _to_rgb(img)
    if mode == "stretch":
        return img.resize(size, Image.LANCZOS)
    if mode == "cover":
        return ImageOps.fit(img, size, Image.LANCZOS)
    if mode == "contain":
        scale = min(size[0] / img.width, size[1] / img.height)
        inner_size = (max(1, min(size[0], round(img.width * scale))),
                      max(1, min(size[1], round(img.height * scale))))
        inner = img.resize(inner_size, Image.LANCZOS)
        canvas = Image.new("RGB", size, "white")
        canvas.paste(inner, ((size[0] - inner.width) // 2, (size[1] - inner.height) // 2))
        return canvas
    raise ValueError(f"unknown fit mode: {mode}")


#: Stucki error diffusion kernel: (weight, dx, dy), weights sum to 42
_STUCKI = ((8, 1, 0), (4, 2, 0), (2, -2, 1), (4, -1, 1), (8, 0, 1), (4, 1, 1), (2, 2, 1),
           (1, -2, 2), (2, -1, 2), (4, 0, 2), (2, 1, 2), (1, 2, 2))


def _keep_in_range(r: int, g: int, b: int) -> tuple[int, int, int]:
    """Bring a pixel that collected too much error back into 0-255 while
    keeping its hue: a negative channel lifts all three channels together, a
    channel above 255 scales all three down together; then clamp."""
    low = min(r, g, b)
    if low < 0:
        lift = int(255 * -low / (255 - low))
        r, g, b = r + lift, g + lift, b + lift
    high = max(r, g, b)
    if high > 255:
        scale = 255 / high
        r, g, b = int(r * scale), int(g * scale), int(b * scale)
    return (0 if r < 0 else 255 if r > 255 else r,
            0 if g < 0 else 255 if g > 255 else g,
            0 if b < 0 else 255 if b > 255 else b)


def stucki(img: Image.Image, strength: float = 1.0) -> bytes:
    """Palette indices of ``img`` with Stucki error diffusion: raster order,
    nearest palette colour by squared RGB distance (ties: lowest index), the
    error in whole numbers per channel, and hue-preserving range handling
    (_keep_in_range). It looks better on the panel than Floyd-Steinberg.

    ``strength`` < 1 spreads only that share of the error: less grain, more
    banding (0 is plain nearest colour)."""
    w, h = img.size
    raw = img.convert("RGB").tobytes()
    r, g, b = list(raw[0::3]), list(raw[1::3]), list(raw[2::3])
    pal = [c.rgb for c in PALETTE]
    taps = [(wt / 42.0 * strength, dx, dy) for wt, dx, dy in _STUCKI]
    out = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            i = y * w + x
            pr, pg, pb = r[i], g[i], b[i]
            best, bd = 0, None
            for k, (cr, cg, cb) in enumerate(pal):
                d = (cr - pr) ** 2 + (cg - pg) ** 2 + (cb - pb) ** 2
                if bd is None or d < bd:
                    best, bd = k, d
            out[i] = best
            cr, cg, cb = pal[best]
            er, eg, eb = pr - cr, pg - cg, pb - cb
            for f, dx, dy in taps:
                xx, yy = x + dx, y + dy
                if 0 <= xx < w and yy < h:
                    j = yy * w + xx
                    r[j], g[j], b[j] = _keep_in_range(r[j] + int(er * f), g[j] + int(eg * f), b[j] + int(eb * f))
    return bytes(out)


def to_indexed(img: Image.Image, dither: bool = True) -> Image.Image:
    """Map an RGB image onto the 7 device colours ("P" image, indices 0-6);
    ``dither`` uses Stucki error diffusion."""
    if img.size != (WIDTH, HEIGHT):
        img = fit(img)
    if dither:
        q = Image.frombytes("P", (WIDTH, HEIGHT), stucki(_to_rgb(img)))
        q.putpalette(_FLAT_PALETTE)
        return q
    q = _to_rgb(img).quantize(palette=_palette_image(), dither=Image.Dither.NONE)
    # Pillow may pad the palette with black; fold any stray index back to 0.
    if max(q.tobytes()) >= len(PALETTE):
        q = q.point([i if i < len(PALETTE) else 0 for i in range(256)])
    return q


def pack_indices(indices: bytes) -> bytes:
    """Two pixels per byte, first pixel in the high nibble."""
    if len(indices) % 2:
        indices += b"\x00"
    return bytes((h << 4) | lo for h, lo in zip(indices[0::2], indices[1::2]))


def unpack(raw: bytes) -> bytes:
    out = bytearray(len(raw) * 2)
    out[0::2] = bytes(b >> 4 for b in raw)
    out[1::2] = bytes(b & 0x0F for b in raw)
    return bytes(out)


def encode(img: Image.Image, fit_mode: Fit = "contain", dither: bool = True) -> bytes:
    """Any image -> raw frame bytes ready to upload."""
    return pack_indices(to_indexed(fit(img, fit_mode), dither=dither).tobytes())


def preview(raw: bytes) -> Image.Image:
    """Render raw frame bytes as the panel would show them."""
    p = Image.frombytes("P", (WIDTH, HEIGHT), unpack(raw))
    p.putpalette(_FLAT_PALETTE)
    return p.convert("RGB")


_FONT_CANDIDATES = (
    # Windows (CJK capable first)
    r"C:\Windows\Fonts\msjh.ttc",
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\arial.ttf",
    # macOS
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
    # Linux
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
)


def load_font(size: int, path: str | None = None) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """``path`` if given (a file or an installed font name), else a system font that can do CJK."""
    if path:
        try:
            return ImageFont.truetype(path, size)
        except OSError as e:
            raise UlaniError(f"cannot load font {path!r}: {e}") from None
    for candidate in _FONT_CANDIDATES:
        if os.path.exists(candidate):
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default(size=size)


#: Smallest text size render_text will use; below this it refuses instead.
MIN_TEXT_SIZE = 14
# CJK (and fullwidth) text has no spaces, so it may break between any two
# characters; everything else breaks only at whitespace.
_CJK = "\u2e80-\u2fdf\u3000-\u303f\u3040-\u30ff\u3100-\u31ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff\uff00-\uffef"
_TOKEN = re.compile(rf"[^\s{_CJK}]+|\s+|.")


def _wrap(text: str, font, width: int, split_words: bool = False) -> str:
    """Greedy line wrap. Words are split into characters only if ``split_words``."""
    lines = []
    for paragraph in text.split("\n"):
        line = ""
        for token in _TOKEN.findall(paragraph):
            too_long = split_words and not token.isspace() and font.getlength(token) > width
            pieces = list(token) if too_long else [token]
            for piece in pieces:
                if line and font.getlength(line + piece) > width:
                    lines.append(line.rstrip())
                    line = piece.lstrip()
                else:
                    line += piece
        lines.append(line.rstrip())
    return "\n".join(lines)


def render_text(
    text: str,
    colour: str = "black",
    background: str = "white",
    font_path: str | None = None,
    margin: int = 40,
) -> Image.Image:
    """Draw ``text`` (may contain newlines) as large as fits, wrapped and centred."""
    img = Image.new("RGB", (WIDTH, HEIGHT), COLOURS[background].rgb)
    draw = ImageDraw.Draw(img)
    draw.fontmode = "1"  # no anti-aliasing: edges would dither into stray colours
    box_w, box_h = WIDTH - 2 * margin, HEIGHT - 2 * margin

    def layout(split_words: bool):
        size = 300
        while size >= MIN_TEXT_SIZE:
            font = load_font(size, font_path)
            wrapped = _wrap(text, font, box_w, split_words)
            box = draw.multiline_textbbox((0, 0), wrapped, font=font, align="center", spacing=size // 5)
            if box[2] - box[0] <= box_w and box[3] - box[1] <= box_h:
                return size, font, wrapped, box
            size = int(size * 0.9)
        return None

    # Prefer shrinking the text over breaking words; split words only as a last resort.
    found = layout(split_words=False) or layout(split_words=True)
    if found is None:
        raise UlaniError(f"text too long to fit on the panel at {MIN_TEXT_SIZE}px or larger; shorten it")
    size, font, wrapped, (l, t, r, b) = found
    x = (WIDTH - (r - l)) // 2 - l
    y = (HEIGHT - (b - t)) // 2 - t
    draw.multiline_text((x, y), wrapped, font=font, fill=COLOURS[colour].rgb, align="center", spacing=size // 5)
    return img
