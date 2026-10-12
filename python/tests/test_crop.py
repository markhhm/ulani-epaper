import importlib.util
import json
from pathlib import Path

import pytest
from PIL import Image

from ulani_epaper import image, push

ROOT = Path(__file__).resolve().parents[2]
VECTORS = ROOT / "shared" / "vectors" / "crop-vectors.json"


def _generator():
    spec = importlib.util.spec_from_file_location("gen_crop_vectors", ROOT / "python" / "scripts" / "gen_crop_vectors.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_vectors_file_is_up_to_date():
    assert json.loads(VECTORS.read_text(encoding="utf-8")) == json.loads(json.dumps(_generator().build()))


def test_vectors_boxes_and_rejections():
    data = json.loads(VECTORS.read_text(encoding="utf-8"))
    for case in data["crops"]:
        w, h = case["photo"]
        assert list(image.crop_box(image.check_crop(case["crop"], w, h), w, h)) == case["box"]
    for case in data["boxes"]:
        assert list(image.crop_box(case["crop"], *case["size"])) == case["box"]
    for case in data["invalid"]:
        with pytest.raises(ValueError):
            image.check_crop(case["crop"], *case["photo"])
    assert data["boxes"][0]["box"][0] == 251  # 250.5 rounds up, not to even


def _photo(width=1200, height=900):
    img = Image.new("RGB", (width, height), "white")
    img.paste((200, 0, 0), (0, 0, width // 2, height // 2))  # red top-left quarter
    img.paste((0, 0, 200), (width // 2, height // 2, width, height))  # blue bottom-right quarter
    return img


def test_no_crop_is_todays_cover():
    photo = _photo()
    assert image.encode(photo, "cover", crop=None) == image.encode(photo, "cover")


def test_corner_crops_show_that_corner():
    photo = _photo()
    left, top, w, h = image.default_crop(*photo.size)
    w2, h2 = w / 2, h / 2
    tl = image.fit(photo, "cover", crop=(0.0, 0.0, w2, h2))
    br = image.fit(photo, "cover", crop=(1 - w2, 1 - h2, w2, h2))
    assert tl.getpixel((400, 240))[0] > 150 and br.getpixel((400, 240))[2] > 150


def test_contain_ignores_the_crop():
    photo = _photo()
    left, top, w, h = image.default_crop(*photo.size)
    assert image.fit(photo, "contain", crop=(0, 0, w / 2, h / 2)).tobytes() == image.fit(photo, "contain").tobytes()


@pytest.mark.parametrize("crop", [(0.5, 0, 0.9, 0.9), (0, 0, 0.5, 0.5), (-0.1, 0, 1, 0.8), ("a", 0, 1, 1), (0, 0, 1)])
def test_bad_crops_are_rejected(crop):
    with pytest.raises(ValueError):
        image.fit(_photo(), "cover", crop=crop)


def test_exif_rotated_photo_is_cropped_as_displayed(tmp_path):
    raw = _photo(900, 1200)  # stored landscape-in-portrait; EXIF says rotate
    path = tmp_path / "rotated.jpg"
    exif = Image.Exif()
    exif[0x0112] = 6  # rotate 90 degrees clockwise when displayed
    raw.save(path, exif=exif.tobytes(), quality=95)
    with image.open_image(path) as img:
        shown = image.fit(img, "cover", crop=image.default_crop(1200, 900))
    assert shown.size == (image.WIDTH, image.HEIGHT)


def test_prepare_applies_crops_per_page():
    photo = _photo()
    left, top, w, h = image.default_crop(*photo.size)
    frames = push.prepare({1: photo, 2: photo}, crops={2: (0.0, 0.0, w / 2, h / 2)})
    assert frames[1] == image.encode(photo, "cover") and frames[2] != frames[1]
