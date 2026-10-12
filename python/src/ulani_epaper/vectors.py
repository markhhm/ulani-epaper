"""Language-neutral test vectors for other implementations of this library (e.g. Swift).

    python -m ulani_epaper.vectors shared/vectors/ulani-vectors.json   (from the repo root)

(Writes UTF-8 with LF line endings itself; shell redirection is avoided
because Windows PowerShell 5.1 would write UTF-16.)

Byte strings are lowercase hex. Big inputs are given as recipes:
``{"hex": "..."}``, ``{"repeat_hex": "11", "count": 192000}`` or
``{"bands": true}`` / ``{"checker": true}`` (the frames described under
``frame_bands`` / ``frame_checker``).
python/tests/test_vectors.py fails if this output and the committed JSON differ.
"""

from __future__ import annotations

import json
import sys

from . import image
from . import protocol as p

SERIAL = "UP7320EXX0000000"  # placeholder, not a real device


def _input(recipe: dict) -> bytes:
    if "hex" in recipe:
        return bytes.fromhex(recipe["hex"])
    if "repeat_hex" in recipe:
        return bytes.fromhex(recipe["repeat_hex"]) * recipe["count"]
    if recipe.get("bands"):
        return bands_frame()
    if recipe.get("checker"):
        return checker_frame()
    raise ValueError(recipe)


def band_index(x: int) -> int:
    """Palette index of column x in the 7-band test frame."""
    return min(x // (p.WIDTH // 7), 6)


def bands_frame() -> bytes:
    """800x480 frame: 7 vertical bands of palette indices 0..6 (last band wider)."""
    row = bytes(band_index(x) for x in range(p.WIDTH))
    return image.pack_indices(row * p.HEIGHT)


def checker_index(x: int, y: int) -> int:
    """Palette index at (x, y) of the asymmetric test frame."""
    return ((x // 115) + (y // 69)) % 7


def checker_frame() -> bytes:
    """800x480 frame that differs top/bottom and has odd band edges, so a
    vertical/horizontal flip or swapped nibbles all change its CRCs."""
    return image.pack_indices(bytes(checker_index(x, y) for y in range(p.HEIGHT) for x in range(p.WIDTH)))


def build() -> dict:
    inputs = [
        {"hex": ""},
        {"hex": b"123456789".hex()},
        {"hex": bytes(range(256)).hex()},
        {"repeat_hex": "11", "count": p.FRAME_BYTES},
        {"bands": True},
    ]
    return {
        "version": 1,
        "panel": {"width": p.WIDTH, "height": p.HEIGHT, "pixels_per_byte": p.PIXELS_PER_BYTE,
                  "frame_bytes": p.FRAME_BYTES, "user_slots": list(p.USER_SLOTS),
                  "max_chunk": p.MAX_CHUNK},
        "gatt": {"advertised_service": p.ADVERTISED_SERVICE, "service": p.SERVICE,
                 "command": p.CHAR_COMMAND, "image": p.CHAR_IMAGE,
                 "model_number": p.CHAR_MODEL_NUMBER, "firmware_revision": p.CHAR_FIRMWARE_REVISION},
        "palette": [{"index": c.index, "name": c.name, "rgb": list(c.rgb)} for c in image.PALETTE],
        "crc": [{"input": r, "crc16": f"{p.crc16(_input(r)):04x}", "crc32": f"{p.crc32(_input(r)):08x}"}
                for r in inputs],
        "image_header": [
            {"input": r, "slot": slot, "mode": mode, "header": p.build_image_header(_input(r), slot, mode).hex()}
            for r, slot, mode in [
                ({"hex": b"123456789".hex()}, 2, 1),
                ({"repeat_hex": "11", "count": p.FRAME_BYTES}, 1, 1),
                ({"bands": True}, 4, 2),
                ({"checker": True}, 3, 1),
            ]
        ],
        "commands": {
            "unlock": p.CMD_UNLOCK.hex(),
            "battery": p.CMD_BATTERY.hex(),
            "device_info": p.CMD_DEVICE_INFO.hex(),
            "get_slot": p.CMD_GET_SLOT.hex(),
            "disconnect": p.CMD_DISCONNECT.hex(),
            "show_slot": {str(s): p.build_show_slot(s).hex() for s in p.USER_SLOTS},
        },
        "replies": {
            "unlock_ok": p.RSP_UNLOCK_OK.hex(),
            "header": {"ok": p.RSP_HEADER_OK.hex(), "busy": p.RSP_HEADER_BUSY.hex(),
                       "same_image": p.RSP_HEADER_SAME_IMAGE.hex()},
            "data": {"ok": p.RSP_DATA_OK.hex(), "fail": p.RSP_DATA_FAIL.hex()},
            "show_slot_ok": p.RSP_SHOW_SLOT_OK.hex(),
            "device_ready": "0500",
            "battery": [
                {"reply": raw.hex(), "level": b.level, "charging": b.charging}
                for raw in (bytes([6, 0]), bytes([6, 3]), bytes([6, 5]), bytes([6, 6]))
                for b in [p.parse_battery(raw)]
            ],
            "get_slot": [{"reply": "0c022b9f7a43", "slot": 2, "crc32": "2b9f7a43"},
                         {"reply": "0c03ffffffff", "slot": 3, "crc32": "ffffffff"}],
            "device_info": [{
                "reply": (bytes.fromhex("0a112233445566") + SERIAL.encode()).hex(),
                "mac": "11:22:33:44:55:66", "serial": SERIAL,
            }],
        },
        "packing": [
            {"indices": idx, "packed": image.pack_indices(bytes(idx)).hex()}
            for idx in ([1, 2, 3, 4], [0, 6, 6, 0], [5], [1] * 8)
        ],
        "nearest_colour": [
            # samples far from any decision boundary: every nearest-colour
            # implementation must agree on these
            {"rgb": list(rgb), "index": index}
            for rgb, index in [
                ((5, 5, 5), 0), ((240, 240, 240), 1), ((10, 240, 20), 2), ((20, 20, 230), 3),
                ((245, 10, 10), 4), ((250, 250, 20), 5), ((250, 120, 10), 6),
            ]
        ],
        "frame_bands": {
            "description": "800x480, palette index = min(x // 114, 6) for every row; no dithering",
            "crc32": f"{p.crc32(bands_frame()):08x}",
            "crc16": f"{p.crc16(bands_frame()):04x}",
            "first_row_packed": bands_frame()[: p.WIDTH // 2].hex(),
        },
        "frame_checker": {
            "description": ("800x480, palette index = ((x // 115) + (y // 69)) % 7; no dithering. "
                            "Asymmetric: a vertical or horizontal flip, or low-nibble-first packing, "
                            "changes the CRCs"),
            "crc32": f"{p.crc32(checker_frame()):08x}",
            "crc16": f"{p.crc16(checker_frame()):04x}",
            "first_row_packed": checker_frame()[: p.WIDTH // 2].hex(),
            "last_row_packed": checker_frame()[-(p.WIDTH // 2):].hex(),
        },
        "push_order": [
            {"shown": shown, "slots": slots, "order": order}
            for shown, slots, order in [
                (2, [1, 2, 3, 4], [1, 3, 4, 2]),
                (4, [2, 4], [2, 4]),
                (3, [4, 1], [1, 4]),
                (1, [1], [1]),
            ]
        ],
    }


def dumps() -> str:
    return json.dumps(build(), indent=1, ensure_ascii=True) + "\n"


if __name__ == "__main__":
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as f:
            f.write(dumps())
    else:
        sys.stdout.write(dumps())
