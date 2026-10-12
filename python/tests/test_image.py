import time

import pytest
from PIL import Image, ImageFile

from ulani_epaper import image as im
from ulani_epaper.protocol import FRAME_BYTES, HEIGHT, WIDTH, UlaniError


def _histogram(img: Image.Image) -> dict[str, float]:
    """Share of each palette colour after encoding (no dithering)."""
    idx = im.to_indexed(im.fit(img, "stretch"), dither=False).tobytes()
    return {c.name: idx.count(c.index) / len(idx) for c in im.PALETTE if idx.count(c.index)}


def _bands(colours, size=(WIDTH, HEIGHT)):
    """Vertical bands of exact colours, one per entry."""
    img = Image.new("RGB", size)
    band = size[0] // len(colours)
    for i, rgb in enumerate(colours):
        img.paste(rgb, (i * band, 0, (i + 1) * band if i < len(colours) - 1 else size[0], size[1]))
    return img, band


def test_palette_order_matches_device_indices():
    names = [c.name for c in im.PALETTE]
    assert names == ["black", "white", "green", "blue", "red", "yellow", "orange"]
    assert [c.index for c in im.PALETTE] == list(range(7))


def test_pack_two_pixels_per_byte_high_nibble_first():
    assert im.pack_indices(bytes([1, 2, 3, 4])) == bytes([0x12, 0x34])


def test_unpack_is_inverse_of_pack():
    idx = bytes([0, 1, 2, 3, 4, 5, 6, 0])
    assert im.unpack(im.pack_indices(idx)) == idx


def test_exact_palette_colours_map_to_their_index():
    img, band = _bands([c.rgb for c in im.PALETTE])
    for dither in (False, True):
        indexed = im.to_indexed(img, dither=dither)
        for c in im.PALETTE:
            x = c.index * band + band // 2
            assert indexed.getpixel((x, HEIGHT // 2)) == c.index, (dither, c.name)


def test_indexed_image_uses_only_palette_indices():
    gradient = Image.linear_gradient("L").convert("RGB").resize((WIDTH, HEIGHT))
    indexed = im.to_indexed(gradient, dither=True)
    assert set(indexed.tobytes()) <= set(range(7))


def test_encode_white_frame():
    raw = im.encode(Image.new("RGB", (WIDTH, HEIGHT), "white"))
    assert len(raw) == FRAME_BYTES
    assert raw == b"\x11" * FRAME_BYTES


def test_fit_contain_letterboxes_with_white():
    tall = Image.new("RGB", (100, 400), "black")
    out = im.fit(tall, "contain")
    assert out.size == (WIDTH, HEIGHT)
    assert out.getpixel((0, 0)) == (255, 255, 255)
    assert out.getpixel((WIDTH // 2, HEIGHT // 2)) == (0, 0, 0)


def test_fit_cover_fills_the_frame():
    tall = Image.new("RGB", (100, 400), "black")
    out = im.fit(tall, "cover")
    assert out.size == (WIDTH, HEIGHT)
    assert out.getpixel((0, 0)) == (0, 0, 0)


def test_fit_stretch():
    assert im.fit(Image.new("RGB", (10, 10)), "stretch").size == (WIDTH, HEIGHT)


def test_preview_round_trip_colours():
    img, band = _bands([c.rgb for c in im.PALETTE])
    preview = im.preview(im.encode(img, dither=False))
    assert preview.size == (WIDTH, HEIGHT)
    for c in im.PALETTE:
        assert preview.getpixel((c.index * band + band // 2, 10)) == c.rgb


def test_render_text_produces_full_frame():
    out = im.render_text("Hello")
    assert out.size == (WIDTH, HEIGHT)
    # something other than the background got drawn
    assert out.convert("L").getextrema()[0] < 255


@pytest.mark.parametrize("mode", ["I;16", "I;16B", "I;16L"])
def test_16_bit_greyscale_is_scaled_not_clipped(mode):
    # Pillow clips I;16 values above 255 when converting straight to RGB
    dark = Image.new(mode, (40, 40), 8000)  # ~12 % grey -> should map to black
    assert _histogram(dark) == {"black": 1.0}
    gradient = Image.linear_gradient("L").resize((64, 64)).convert("I")
    gradient = gradient.point(lambda v: v * 257)  # spread to the full 16-bit range
    assert set(_histogram(gradient)) >= {"black", "white"}


@pytest.mark.parametrize("make", [
    lambda: Image.new("PA", (10, 10), (0, 0)),
    lambda: Image.new("LA", (10, 10), (0, 0)),
    lambda: Image.new("RGBA", (10, 10), (0, 0, 0, 0)),
])
def test_transparent_pixels_become_white(make):
    assert _histogram(make()) == {"white": 1.0}


def test_png_colour_key_transparency_becomes_white(tmp_path):
    path = tmp_path / "key.png"
    Image.new("RGB", (10, 10), (0, 0, 0)).save(path, transparency=(0, 0, 0))
    with Image.open(path) as img:
        assert _histogram(img) == {"white": 1.0}


def test_16_bit_png_colour_key_transparency_becomes_white(tmp_path):
    # The key is in 16-bit units: 20000 must become 77 after scaling, or the
    # transparent half stays dark grey (-> black) instead of white.
    path = tmp_path / "key16.png"
    img = Image.new("I", (10, 10), 0)          # right half: opaque black
    img.paste(20000, (0, 0, 5, 10))            # left half: the transparent key colour
    img.convert("I;16").save(path, transparency=20000)  # (paste on I;16 mangles ints)
    with Image.open(path) as src:
        rgb = im._to_rgb(src)
    assert rgb.getpixel((0, 0)) == (255, 255, 255)  # transparent -> white
    assert rgb.getpixel((9, 9)) == (0, 0, 0)        # opaque black stays black


@pytest.mark.parametrize("size", [(1, 2000), (2000, 1), (2, 5000)])
def test_fit_contain_handles_extremely_thin_images(size):
    assert im.fit(Image.new("RGB", size, "black"), "contain").size == (WIDTH, HEIGHT)


def test_render_text_wraps_long_text_inside_the_margins():
    text = "這是一段很長很長的中文句子，需要自動換行才能放進畫面。" * 3 + " lorem ipsum dolor sit amet" * 6
    out = im.render_text(text, margin=40)
    ink = Image.eval(out.convert("L"), lambda v: 255 - v).getbbox()
    assert ink is not None
    left, top, right, bottom = ink
    assert left >= 40 and top >= 40 and right <= WIDTH - 40 and bottom <= HEIGHT - 40


@pytest.mark.parametrize("text", [
    "Привет мир, как дела сегодня? Всё хорошо, спасибо большое за вопрос.",
    "Café crème brûlée déjà vu naïve façade über straße Ελληνικά γράμματα",
    "Combining é marks and emoji 👍🏽 modifiers stay whole " * 2,
])
def test_wrap_never_breaks_inside_words_that_fit(text):
    font = im.load_font(48)
    words = set(text.split())
    for line in im._wrap(text, font, 400).split("\n"):
        assert set(line.split()) <= words, line


def test_wrap_still_breaks_cjk_between_characters():
    font = im.load_font(48)
    lines = im._wrap("這是一段沒有空白的中文句子需要在字與字之間換行", font, 300).split("\n")
    assert len(lines) > 1 and all(font.getlength(line) <= 300 for line in lines)


def test_render_text_splits_a_word_only_when_nothing_else_fits():
    out = im.render_text("x" * 400)  # one word too long for any line at 14 px
    assert out.size == (WIDTH, HEIGHT)


def test_render_text_refuses_text_that_cannot_fit():
    with pytest.raises(UlaniError, match="too long"):
        im.render_text("字" * 5000)


def header_only_png(path, width, height):
    """A PNG that only declares its size (no pixel data): enough to trigger Pillow's size checks."""
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IEND", b""))
    return path


def _jpeg(path, size, orientation=None, colour="red"):
    """A solid JPEG of ``size``; ``orientation`` is the EXIF orientation tag (1-8), if any."""
    exif = Image.Exif()
    if orientation:
        exif[0x0112] = orientation
    Image.new("RGB", size, colour).save(path, quality=80, exif=exif.tobytes())
    return path


def test_limit_photo_landscape():
    assert im.limit_photo(Image.new("RGB", (6000, 4000), "red")).size == (3240, 2160)  # the height binds


def test_limit_photo_portrait():
    assert im.limit_photo(Image.new("RGB", (4000, 6000), "red")).size == (2160, 3240)  # the 2160 x 3840 box


def test_limit_photo_wide_panorama():
    assert im.limit_photo(Image.new("RGB", (12000, 1000), "red")).size == (3840, 320)  # the width binds


def test_limit_photo_square_counts_as_landscape():
    assert im.limit_photo(Image.new("RGB", (7000, 7000), "red")).size == (2160, 2160)


def test_limit_photo_constants():
    assert im.MAX_PHOTO_SIZE == (3840, 2160)
    assert im.PHOTO_PIXEL_LIMIT == 50_000_000


@pytest.mark.parametrize("size", [(1200, 900), (3840, 2160), (2160, 3840), (1, 1)])
def test_limit_photo_small_untouched(size):
    photo = Image.effect_noise(size, 40).convert("RGB")
    limited = im.limit_photo(photo)
    assert limited.size == size and limited.tobytes() == photo.tobytes()


def test_limit_photo_rounds_halves_up():
    # 5001 x 4320 -> 2160 high; the width is 2500.5, which rounds to 2501 (not to even)
    assert im.limit_photo(Image.new("RGB", (5001, 4320))).size == (2501, 2160)


def test_limit_photo_applies_exif_orientation_first(tmp_path):
    path = _jpeg(tmp_path / "turned.jpg", (6000, 4000), orientation=6)  # shown as 4000 x 6000
    with Image.open(path) as img:
        assert im.limit_photo(img).size == (2160, 3240)


def test_open_image_is_limited_and_fast(tmp_path):
    path = _jpeg(tmp_path / "huge.jpg", (7000, 7000))  # 49 MP
    started = time.monotonic()
    with im.open_image(path) as img:
        assert img.size == (2160, 2160)
    assert time.monotonic() - started < 2


@pytest.mark.parametrize("size, orientation", [
    ((7001, 4099), None), ((4097, 6999), None), ((6001, 3999), 8), ((3999, 6001), 6), ((9000, 3000), 3),
])
def test_open_image_size_is_the_same_with_or_without_the_jpeg_shortcut(tmp_path, size, orientation):
    # open_image decodes JPEGs at a reduced scale; the result must still be what limit_photo gives
    path = _jpeg(tmp_path / "p.jpg", size, orientation)
    with Image.open(path) as full:
        expected = im.limit_photo(full).size
    with im.open_image(path) as img:
        assert img.size == expected


def test_open_image_leaves_photos_within_4k_alone(tmp_path):
    path = tmp_path / "ok.png"
    Image.effect_noise((1200, 900), 40).convert("RGB").save(path)
    with Image.open(path) as raw, im.open_image(path) as img:
        assert img.size == (1200, 900) and img.tobytes() == raw.tobytes()


def watch_decoding(monkeypatch):
    """Start recording the calls of the pixel decoder (Image.load); returns the list of calls."""
    calls = []
    for cls in (Image.Image, ImageFile.ImageFile):
        def spy(self, *args, _original=cls.load, **kwargs):
            calls.append(self)
            return _original(self, *args, **kwargs)
        monkeypatch.setattr(cls, "load", spy)
    return calls


def test_open_image_refuses_over_the_limit(tmp_path, monkeypatch):
    path = _jpeg(tmp_path / "small.jpg", (400, 300))
    decoded = watch_decoding(monkeypatch)
    with pytest.raises(im.PhotoTooLarge) as e:
        im.open_image(path, pixel_limit=100_000)
    assert e.value.megapixels == 0
    assert isinstance(e.value, UlaniError)
    assert not decoded


def test_open_image_accepts_exactly_the_limit(tmp_path, monkeypatch):
    path = _jpeg(tmp_path / "small.jpg", (400, 300))
    decoded = watch_decoding(monkeypatch)
    with im.open_image(path, pixel_limit=120_000) as img:
        assert img.size == (400, 300)
    assert decoded  # the spy does see decoding, so the refusal test above means something


def test_photo_too_large_counts_megapixels_rounding_halves_up(tmp_path):
    path = _jpeg(tmp_path / "wide.jpg", (2500, 1000))  # 2.5 MP
    with pytest.raises(im.PhotoTooLarge) as e:
        im.open_image(path, pixel_limit=1_000_000)
    assert e.value.megapixels == 3
    assert str(e.value) == "the photo has about 3 megapixels; shrink it to 50 megapixels or less first"


def test_open_image_refuses_a_header_that_declares_more_than_50_megapixels(tmp_path):
    path = header_only_png(tmp_path / "64mp.png", 8000, 8000)  # no pixel data: it is refused before decoding
    with pytest.raises(im.PhotoTooLarge) as e:
        im.open_image(path)
    assert e.value.megapixels == 64


def test_open_image_turns_decompression_bombs_into_too_large_photos(tmp_path):
    path = header_only_png(tmp_path / "200mp.png", 16320, 12240)  # a 200 MP phone photo, over Pillow's cap
    with pytest.raises(im.PhotoTooLarge) as e:
        im.open_image(path)
    assert e.value.megapixels == 200


def test_open_image_keeps_a_plain_error_when_pillow_gives_no_pixel_count(tmp_path, monkeypatch):
    def bomb(*args, **kwargs):
        raise Image.DecompressionBombError("odd words")

    monkeypatch.setattr(Image, "open", bomb)
    with pytest.raises(UlaniError, match="too large") as e:
        im.open_image(tmp_path / "x.png")
    assert not isinstance(e.value, im.PhotoTooLarge)


def test_open_image_leaves_the_file_closed(tmp_path):
    ok = _jpeg(tmp_path / "ok.jpg", (400, 300))
    big = _jpeg(tmp_path / "big.jpg", (400, 300))
    with im.open_image(ok):
        ok.unlink()  # Windows refuses to delete a file that is still open
    with pytest.raises(im.PhotoTooLarge) as refused:
        im.open_image(big, pixel_limit=1)
    big.unlink()  # `refused` still holds the traceback, so only an explicit close can have released the file


def test_load_font_reports_a_missing_font_file():
    with pytest.raises(UlaniError, match="font"):
        im.load_font(20, "no/such/font.ttf")


def gradient():
    img = Image.new("RGB", (800, 480))
    img.putdata([(x * 255 // 799, 120, 255 - x * 255 // 799) for y in range(480) for x in range(800)])
    return img


def changes(indices: bytes) -> int:
    return sum(1 for a, b in zip(indices, indices[1:]) if a != b)


def test_lower_grain_strength_gives_calmer_pixels():
    full, soft = im.stucki(gradient(), 1.0), im.stucki(gradient(), 0.5)
    assert changes(soft) < changes(full)  # fewer colour flips: less grain


def test_grain_levels_are_offered_from_strong_to_smooth():
    assert list(im.GRAIN.values()) == sorted(im.GRAIN.values(), reverse=True)
    assert im.GRAIN["標準"] == 1.0  # the full Stucki kernel


def test_render_text_is_not_antialiased():
    # anti-aliased edges would be mapped to stray yellow/orange pixels
    out = im.render_text("Hello 你好", colour="red", background="white")
    assert {rgb for _, rgb in out.getcolors(1 << 16)} == {(255, 0, 0), (255, 255, 255)}


@pytest.mark.parametrize("colour, expected", [
    # Google Calendar's calendar colours (what the API returns) ...
    ("#f83a22", "red"), ("#f691b2", "red"), ("#ff7537", "orange"), ("#ffad46", "orange"),
    ("#ac725e", "orange"), ("#fad165", "yellow"), ("#fbe983", "yellow"), ("#16a765", "green"),
    ("#7bd148", "green"), ("#92e1c0", "green"), ("#9fe1e7", "blue"), ("#4986e7", "blue"),
    ("#9a9cff", "blue"), ("#cd74e6", "blue"), ("#c2c2c2", "black"), ("#cabdbf", "black"),
    # ... and the names in its colour picker
    ("#d50000", "red"), ("#e67c73", "red"), ("#f4511e", "orange"), ("#f6bf26", "yellow"),
    ("#33b679", "green"), ("#0b8043", "green"), ("#039be5", "blue"), ("#3f51b5", "blue"),
    ("#7986cb", "blue"), ("#8e24aa", "blue"), ("#616161", "black"),
])
def test_accent_maps_calendar_colours_by_hue(colour, expected):
    assert im.accent(colour) == expected


@pytest.mark.parametrize("bad", ["", "blue", "#12345", "#gggggg", None])
def test_accent_falls_back_for_missing_or_bad_colours(bad):
    assert im.accent(bad) == "black"
    assert im.accent(bad, default="blue") == "blue"
