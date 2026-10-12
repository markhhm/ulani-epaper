import json
from pathlib import Path

from PIL import Image

from ulani_epaper import image, vectors
from ulani_epaper import protocol as p

VECTORS = Path(__file__).resolve().parents[2] / "shared" / "vectors" / "ulani-vectors.json"


def test_committed_vectors_match_the_library():
    # regenerate (from the repo root): python -m ulani_epaper.vectors shared/vectors/ulani-vectors.json
    assert json.loads(VECTORS.read_text(encoding="utf-8")) == vectors.build()


def test_nearest_colour_samples_hold_for_this_library():
    for sample in vectors.build()["nearest_colour"]:
        img = Image.new("RGB", (p.WIDTH, p.HEIGHT), tuple(sample["rgb"]))
        indexed = image.to_indexed(img, dither=False)
        assert set(indexed.tobytes()) == {sample["index"]}, sample


def test_bands_frame_equals_encoding_the_band_image():
    img = Image.new("RGB", (p.WIDTH, p.HEIGHT))
    for x in range(p.WIDTH):
        img.paste(image.PALETTE[vectors.band_index(x)].rgb, (x, 0, x + 1, p.HEIGHT))
    assert image.encode(img, dither=False) == vectors.bands_frame()


def test_checker_frame_equals_encoding_the_checker_image():
    img = Image.new("RGB", (p.WIDTH, p.HEIGHT))
    img.putdata([image.PALETTE[vectors.checker_index(x, y)].rgb for y in range(p.HEIGHT) for x in range(p.WIDTH)])
    assert image.encode(img, dither=False) == vectors.checker_frame()


def test_checker_vector_catches_flips_and_nibble_order():
    frame = vectors.checker_frame()
    crc = p.crc32(frame)
    rows = [frame[i:i + p.WIDTH // 2] for i in range(0, len(frame), p.WIDTH // 2)]
    flipped_v = b"".join(reversed(rows))
    swapped = bytes(((b & 0x0F) << 4) | (b >> 4) for b in frame)
    idx = image.unpack(frame)
    flipped_h = image.pack_indices(b"".join(idx[y * p.WIDTH:(y + 1) * p.WIDTH][::-1] for y in range(p.HEIGHT)))
    assert len({crc, p.crc32(flipped_v), p.crc32(swapped), p.crc32(flipped_h)}) == 4


def test_push_order_vectors_follow_the_rule():
    for case in vectors.build()["push_order"]:
        others = sorted(s for s in case["slots"] if s != case["shown"])
        tail = [case["shown"]] if case["shown"] in case["slots"] else []
        assert case["order"] == others + tail
