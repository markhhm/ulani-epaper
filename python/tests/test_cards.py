"""The card store (牌卡): cards.json + backgrounds/ in the config folder, and the .paperhue-card file."""

import io
import json
import zipfile

import pytest
from PIL import Image

from ulani_epaper import cards
from ulani_epaper.cards import Background, Card, TextBox
from ulani_epaper.protocol import UlaniError


def box(text="暫離", **kw):
    return TextBox(text, **{"box": (0.1, 0.2, 0.8, 0.3), **kw})


def photo(tmp_path, size=(1000, 600), name="p.png"):
    path = tmp_path / name
    left = Image.new("RGB", size, (255, 0, 0))
    left.paste((0, 0, 255), (size[0] // 2, 0, size[0], size[1]))
    left.save(path)
    return path


def test_round_trip_and_file_shape(tmp_path):
    card = cards.add(Card(texts=(box("開會中\n15:00 回來", size=60, color="white", outline=True,
                                      outline_color="black", align="left"), box("Hi", color="red"))),
                     folder=tmp_path)
    assert cards.load(tmp_path) == [card]
    raw = json.loads((tmp_path / "cards.json").read_text(encoding="utf-8"))
    assert raw["version"] == 1 and raw["cards"][0]["id"] == card.id
    assert raw["cards"][0]["background"] == {"color": "white"}
    assert raw["cards"][0]["texts"][0] == {"text": "開會中\n15:00 回來", "box": [0.1, 0.2, 0.8, 0.3], "size": 60,
                                           "color": "white", "outline": True, "outline_color": "black",
                                           "align": "left"}


@pytest.mark.parametrize("bad", [
    Card(texts=tuple(box(f"{i}") for i in range(9))),  # at most 8 boxes
    Card(texts=(box("字" * 81),)),
    Card(texts=(box("  "),)),
    Card(texts=(box(color="purple"),)),
    Card(texts=(box(outline_color="grey"),)),
    Card(texts=(box(align="justify"),)),
    Card(texts=(box(size=5),)),
    Card(texts=(TextBox("x", box=(0.5, 0.2, 0.8, 0.3)),)),  # leaves the screen
    Card(background=Background(color="pink")),
    Card(background=Background(image="../x.jpg")),
])
def test_invalid_cards_are_refused_and_nothing_is_written(tmp_path, bad):
    with pytest.raises(ValueError):
        cards.add(bad, folder=tmp_path)
    assert not (tmp_path / "cards.json").exists()


def test_text_is_stored_normalised(tmp_path):
    card = cards.add(Card(texts=(box("  A\r\nB  "),)), folder=tmp_path)
    assert card.texts[0].text == "A\nB"


def test_a_photo_is_copied_in_upright_and_capped_at_4k(tmp_path):
    src = photo(tmp_path, (5000, 2500))
    config = tmp_path / "cfg"
    card = cards.add(Card(background=Background(crop=(0.0, 0.0, 5 / 6, 1.0)), texts=(box(),)), photo=src, folder=config)
    stored = config / "backgrounds" / card.background.image
    assert card.background.image == f"{card.id}.jpg" and card.background.crop == (0.0, 0.0, 5 / 6, 1.0)
    with Image.open(stored) as img:
        assert img.size == (3840, 1920)  # capped like every photo (image.open_image)
    assert src.exists()  # the user's file is left alone


def test_a_crop_must_suit_the_stored_photo(tmp_path):
    with pytest.raises(ValueError):
        cards.add(Card(background=Background(crop=(0.0, 0.0, 0.5, 1.0))), photo=photo(tmp_path), folder=tmp_path / "c")
    assert not (tmp_path / "c" / "cards.json").exists()


def test_update_changes_a_card_and_swaps_its_photo(tmp_path):
    cfg = tmp_path / "cfg"
    card = cards.add(Card(texts=(box("舊"),)), photo=photo(tmp_path), folder=cfg)
    changed = cards.update(Card(card.id, card.background, (box("新"),)), folder=cfg)
    assert cards.get(card.id, cfg).texts[0].text == "新" and changed.background == card.background
    assert (cfg / "backgrounds" / f"{card.id}.jpg").exists()
    plain = cards.update(Card(card.id, Background(color="yellow"), changed.texts), folder=cfg)
    assert plain.background == Background(color="yellow")
    assert not (cfg / "backgrounds" / f"{card.id}.jpg").exists()  # nothing refers to it any more
    with pytest.raises(UlaniError):
        cards.update(Card("00000000", Background(), (box(),)), folder=cfg)


def test_remove_deletes_the_card_and_its_background(tmp_path):
    cfg = tmp_path / "cfg"
    a = cards.add(Card(texts=(box("a"),)), photo=photo(tmp_path), folder=cfg)
    b = cards.add(Card(texts=(box("b"),)), folder=cfg)
    assert cards.remove(a.id, cfg) == a
    assert cards.load(cfg) == [b] and not list((cfg / "backgrounds").iterdir())
    with pytest.raises(UlaniError):
        cards.remove(a.id, cfg)


def test_a_broken_file_is_reported_and_never_overwritten(tmp_path):
    (tmp_path / "cards.json").write_text("{not json", encoding="utf-8")
    with pytest.raises(UlaniError, match="cards.json"):
        cards.add(Card(texts=(box(),)), folder=tmp_path)
    assert (tmp_path / "cards.json").read_text(encoding="utf-8") == "{not json"


def test_export_and_import_round_trip_between_two_folders(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    card = cards.add(Card(background=Background(crop=(0.5, 0.0, 0.5, 0.5)),
                          texts=(box("牌", outline=True, outline_color="black"),)), photo=photo(tmp_path, (1000, 600)),
                     folder=a)
    file = tmp_path / "x.paperhue-card"
    cards.export_card(card.id, file, a)
    with zipfile.ZipFile(file) as z:
        assert sorted(z.namelist()) == ["background.jpg", "card.json"]
    copy = cards.import_card(file, b)
    assert copy.id != card.id and copy.texts == card.texts and copy.background.crop == card.background.crop
    assert cards.load(b) == [copy] and cards.load(a) == [card]  # the original is untouched
    with Image.open(b / "backgrounds" / copy.background.image) as img:
        assert img.size == (1000, 600)
    again = cards.import_card(file, b)  # importing twice makes two cards
    assert again.id not in (card.id, copy.id) and len(cards.load(b)) == 2


def zipped(tmp_path, files, raw=None):
    path = tmp_path / "bad.paperhue-card"
    if raw is not None:
        path.write_bytes(raw)
        return path
    with zipfile.ZipFile(path, "w") as z:
        for name, data in files.items():
            z.writestr(name, data)
    return path


def card_json(**background):
    return json.dumps({"version": 1, "id": "a1b2c3d4", "background": background or {"color": "red"},
                       "texts": [{"text": "x", "box": [0, 0, 1, 1]}]})


def jpeg_bytes():
    out = io.BytesIO()
    Image.new("RGB", (80, 48), "blue").save(out, "JPEG")
    return out.getvalue()


def damaged(tmp_path, compress_type=zipfile.ZIP_STORED, *, patch=None, scramble=False):
    """A zip whose card.json only fails when read: its deflate data scrambled (``scramble``), or ``patch(data,
    i, central)`` run on the local and the central header (the compression method, the encryption flag)."""
    path = zipped(tmp_path, {})
    with zipfile.ZipFile(path, "w", compress_type) as z:
        z.writestr("card.json", card_json() * 40)
    data = bytearray(path.read_bytes())
    if scramble:
        start = 30 + len("card.json")
        data[start:start + 20] = bytes([255]) * 20  # not a deflate block
    if patch:
        patch(data, data.find(b"PK\x03\x04"), False)  # the local header
        patch(data, data.find(b"PK\x01\x02"), True)  # and the central directory one
    path.write_bytes(bytes(data))
    return path


def set_method(data, i, central):
    data[i + (10 if central else 8)] = 99  # a compression method zipfile cannot read


def set_encrypted(data, i, central):
    data[i + (8 if central else 6)] |= 1


@pytest.mark.parametrize("make", [
    lambda t: t / "missing.paperhue-card",
    lambda t: damaged(t, zipfile.ZIP_DEFLATED, scramble=True),  # a damaged download
    lambda t: damaged(t, patch=set_method),
    lambda t: damaged(t, patch=set_encrypted),
    lambda t: zipped(t, {"card.json": "[" * 30_000 + "]" * 30_000}),  # nested beyond what json reads
    lambda t: zipped(t, {}, raw=b"not a zip"),
    lambda t: zipped(t, {"other.txt": "x"}),  # no card.json
    lambda t: zipped(t, {"card.json": "{"}),
    lambda t: zipped(t, {"card.json": card_json(image="background.jpg")}),  # the image is not in the zip
    lambda t: zipped(t, {"card.json": card_json(image="../evil.jpg"), "../evil.jpg": jpeg_bytes()}),
    lambda t: zipped(t, {"card.json": card_json(image="background.jpg"), "background.jpg": b"not an image"}),
    lambda t: zipped(t, {"card.json": "x" * 70_000}),
])
def test_bad_card_files_are_refused_and_import_nothing(tmp_path, make):
    with pytest.raises(UlaniError):
        cards.import_card(make(tmp_path), tmp_path / "cfg")
    assert not (tmp_path / "cfg" / "cards.json").exists()
    assert not list((tmp_path / "cfg").glob("backgrounds/*"))


def test_a_card_file_made_elsewhere_imports(tmp_path):
    file = zipped(tmp_path, {"card.json": card_json(image="background.jpg", crop=[0, 0, 1, 1]),
                             "background.jpg": jpeg_bytes()})
    card = cards.import_card(file, tmp_path / "cfg")
    assert card.background.image == f"{card.id}.jpg"
