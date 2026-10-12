"""render_card: a card (background + text boxes) as an 800x480 page in the 7 panel colours."""

import functools
import json
import shutil
from pathlib import Path

import pytest
from PIL import Image, ImageChops, ImageDraw

from ulani_epaper import cards, layouts
from ulani_epaper import image as im
from ulani_epaper.cards import Background, Card, TextBox
from ulani_epaper.protocol import UlaniError

FIXTURES = Path(__file__).resolve().parents[2] / "shared" / "layouts" / "card"
GOLDEN = FIXTURES / "golden"
PALETTE = {c.rgb for c in im.PALETTE}
NAMES = ["status", "meme", "quote"]
BLACK, WHITE, YELLOW = (0, 0, 0), (255, 255, 255), (255, 255, 0)


def fixture(name):
    return cards.parse(json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8")))


def render(card):
    return layouts.render_card(card, FIXTURES)


def colours(img):
    return {c for _, c in img.convert("RGB").getcolors(1 << 20)}


def drawn(card, backgrounds=FIXTURES):
    """(text, bounding box) of every string drawn."""
    texts, original = [], ImageDraw.ImageDraw.text

    def recording(self, xy, text, fill=None, font=None, anchor=None, *args, **kwargs):
        texts.append((text, self.textbbox(xy, text, font=font, anchor=anchor)))
        return original(self, xy, text, fill, font, anchor, *args, **kwargs)

    ImageDraw.ImageDraw.text = recording
    try:
        layouts.render_card(card, backgrounds)
    finally:
        ImageDraw.ImageDraw.text = original
    return texts


def one(text="好", box=(0.25, 0.25, 0.5, 0.5), background=Background("white"), **kw):
    return Card("a1b2c3d4", background, (TextBox(text, box, **kw),))


@functools.cache
def rendered(name):
    """(image, drawn strings) of a fixture from one render (a photo takes seconds to dither)."""
    images = []
    texts = layouts.drawn_texts(lambda card, folder: images.append(layouts.render_card(card, folder)),
                                fixture(name), FIXTURES)
    return images[0], texts


@pytest.mark.parametrize("name", NAMES)
def test_every_fixture_renders_in_panel_colours(name):
    img = rendered(name)[0]
    assert img.size == (800, 480) and colours(img) <= PALETTE


@pytest.mark.parametrize("name", ["status", "quote"])
def test_rendering_is_deterministic(name):
    assert render(fixture(name)).tobytes() == rendered(name)[0].tobytes()


@pytest.mark.parametrize("name", NAMES)
def test_draws_exactly_the_golden_text(name):
    expected = (GOLDEN / f"card_{name}.txt").read_text(encoding="utf-8").splitlines()
    assert rendered(name)[1] == expected


# Regenerate after an intended design change (and look at every image):
#   python -m ulani_epaper.layouts shared/layouts/card shared/layouts/card/golden  (from the repo root)
@pytest.mark.parametrize("name", NAMES)
def test_matches_the_golden_render(name):
    with Image.open(GOLDEN / f"card_{name}.png") as g:
        expected = g.convert("RGB")
    diff = ImageChops.difference(rendered(name)[0].convert("RGB"), expected).convert("L")
    different = 1 - diff.histogram()[0] / (800 * 480)
    assert different <= 0.005, f"{name}: {different:.2%} of pixels differ"


def test_write_golden_handles_card_fixtures(tmp_path):
    (tmp_path / "in").mkdir()
    shutil.copy(FIXTURES / "quote.json", tmp_path / "in")
    written = layouts.write_golden(str(tmp_path / "in"), str(tmp_path / "out"))
    assert [Path(p).name for p in written] == ["card_quote.png"]
    assert (tmp_path / "out" / "card_quote.txt").read_text(encoding="utf-8") == (GOLDEN / "card_quote.txt").read_text(
        encoding="utf-8")


@pytest.mark.parametrize("colour", ["white", "orange", "blue"])
def test_a_colour_background_is_that_ink_all_over(colour):
    assert colours(layouts.render_card(Card("a1b2c3d4", Background(colour)))) == {im.COLOURS[colour].rgb}


@pytest.mark.parametrize("align", ["left", "center", "right"])
def test_text_is_aligned_inside_its_box(align):
    (_, (left, top, right, bottom)), = drawn(one(align=align, size=40))
    assert left >= 200 and right <= 600 and 120 - 4 <= top and bottom <= 360  # glyphs may rise a few px above the box
    expected = {"left": left - 200, "center": (left + right) / 2 - 400, "right": right - 600}[align]
    assert abs(expected) <= 4  # the glyph's own side bearing


def test_long_text_wraps_in_the_box_and_is_cut_when_the_box_is_too_short():
    tall = drawn(one("字" * 60, box=(0.2, 0.1, 0.3, 0.8), size=30))
    assert len(tall) > 3 and not tall[-1][0].endswith("…")  # all of it, in several lines
    short = drawn(one("字" * 80, box=(0.2, 0.1, 0.3, 0.2), size=30))
    assert len(short) == 2 and short[-1][0].endswith("…")
    for _, (left, top, right, bottom) in tall + short:
        assert 160 <= left and right <= 400 and 48 - 4 <= top and bottom <= 432  # the box: x 160..400, y 48..432


def test_line_breaks_start_new_lines():
    assert [t for t, _ in drawn(one("上\n下", size=40))] == ["上", "下"]


def test_outline_draws_in_its_own_ink_and_stays_inside_the_box_sideways():
    box, yellow = (0.25, 0.25, 0.5, 0.5), Image.new("RGB", (800, 480), YELLOW)
    plain = layouts.render_card(one("字字", box, Background("yellow"), color="white", size=64))
    assert colours(plain) == {YELLOW, WHITE}
    for align, edge in (("left", 0), ("right", 2)):  # the box is x 200..600
        outlined = layouts.render_card(one("字字", box, Background("yellow"), color="white", size=64, outline=True,
                                           outline_color="black", align=align))
        assert colours(outlined) == {YELLOW, WHITE, BLACK}
        ink = ImageChops.difference(outlined, yellow).getbbox()  # (left, top, right, bottom)
        assert ink[edge] in (range(200, 260) if edge == 0 else range(541, 601))


def test_a_photo_background_is_cropped_and_dithered(tmp_path):
    src = Image.new("RGB", (1000, 600), (255, 0, 0))
    src.paste((0, 0, 255), (500, 0, 1000, 600))  # red left half, blue right half
    src.save(tmp_path / "p.png")
    right = layouts.render_card(Card("a1b2c3d4", Background(image="p.png", crop=(0.5, 0.0, 0.5, 0.5))), tmp_path)
    assert colours(right) == {(0, 0, 255)}  # only the right half's top, not the red


def test_a_missing_background_file_is_reported(tmp_path):
    with pytest.raises(UlaniError, match="p.png"):
        layouts.render_card(Card("a1b2c3d4", Background(image="p.png")), tmp_path)


def test_the_stored_background_is_found_in_the_config_folder(tmp_path):
    src = tmp_path / "p.png"
    Image.new("RGB", (100, 60), (0, 255, 0)).save(src)
    card = cards.add(Card(texts=(TextBox("x", (0, 0, 1, 1)),)), photo=src)  # into the (test) config folder
    assert (0, 255, 0) in colours(layouts.render_card(card))
