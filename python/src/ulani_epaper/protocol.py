"""Wire protocol of the ULANI e-paper device (P7320E-B).

Everything here is pure: byte layouts, checksums and response parsing.
See shared/PROTOCOL.md for the full description.
"""

from __future__ import annotations

import zlib
from dataclasses import dataclass
from typing import Iterator

# --- GATT layout ----------------------------------------------------------

#: 16-bit service UUID the device advertises (used for scanning).
ADVERTISED_SERVICE = "0000a200-0000-1000-8000-00805f9b34fb"
SERVICE = "1234a200-7cbc-11e9-8f9e-2a86e4085a59"
#: Commands are written here; replies arrive as notifications here.
CHAR_COMMAND = "1234a201-7cbc-11e9-8f9e-2a86e4085a59"
#: Raw image data is streamed here; the final result is notified here.
CHAR_IMAGE = "1234a202-7cbc-11e9-8f9e-2a86e4085a59"
CHAR_MODEL_NUMBER = "00002a24-0000-1000-8000-00805f9b34fb"
CHAR_FIRMWARE_REVISION = "00002a26-0000-1000-8000-00805f9b34fb"

# --- Panel ----------------------------------------------------------------

WIDTH = 800
HEIGHT = 480
PIXELS_PER_BYTE = 2
FRAME_BYTES = WIDTH * HEIGHT // PIXELS_PER_BYTE

#: Slots 1-4 are the four pages the button cycles through.
USER_SLOTS = range(1, 5)
#: Firmware v1.0.09 does not answer headers for slots outside 1-4 (tried
#: with 16), so only 1-4 are used.
IGNORED_SLOT = 16
#: Header "mode" byte. Paperhue always sends 1 (tested); other values are
#: untested.
DEFAULT_MODE = 1

#: Largest image chunk written per packet.
MAX_CHUNK = 230
ATT_HEADER = 3

# --- Commands (written to CHAR_COMMAND) -----------------------------------

#: Unlock: opcode 04 followed by the fixed ASCII bytes "NB".
CMD_UNLOCK = bytes([0x04, 0x4E, 0x42])
CMD_BATTERY = bytes([0x06, 0x00])
CMD_DEVICE_INFO = bytes([0x0A, 0x00])
CMD_GET_SLOT = bytes([0x0C, 0x00])
CMD_DISCONNECT = bytes([0x09, 0x03])

OP_IMAGE_HEADER = 0x01
OP_IMAGE_DATA = 0x02
OP_UNLOCK = 0x04
OP_BATTERY = 0x06
OP_DISCONNECT = 0x09
OP_DEVICE_INFO = 0x0A
#: Switches the page shown (like pressing the button).
OP_SHOW_SLOT = 0x0B
OP_GET_SLOT = 0x0C

# --- Replies --------------------------------------------------------------

RSP_UNLOCK_OK = bytes([0x04, 0x00])
RSP_HEADER_OK = bytes([0x01, 0x00])
RSP_HEADER_BUSY = bytes([0x01, 0x01])
RSP_HEADER_SAME_IMAGE = bytes([0x01, 0x02])
RSP_DATA_OK = bytes([0x02, 0x00])
RSP_DATA_FAIL = bytes([0x02, 0x01])
RSP_SHOW_SLOT_OK = bytes([0x0B, 0x00])

BATTERY_CHARGING = 6


class UlaniError(Exception):
    """Base class for every error this package raises on purpose."""


class ProtocolError(UlaniError):
    """The device sent something we did not expect."""


@dataclass(frozen=True)
class Battery:
    #: 0 (lowest: the battery is low) .. 5 (full); None while charging.
    level: int | None
    charging: bool


@dataclass(frozen=True)
class DeviceInfo:
    mac: str
    serial: str


def crc16(data: bytes) -> int:
    """CRC-16/XMODEM (poly 0x1021, init 0), as used in the image header."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def build_image_header(data: bytes, slot: int, mode: int = DEFAULT_MODE) -> bytes:
    """13-byte header announcing an image upload.

    ``01 | len (u32 BE) | slot | mode | crc32 (BE) | crc16 (BE)``
    """
    if not 0 <= slot <= 0xFF:
        raise ValueError(f"slot must fit in one byte, got {slot}")
    if not 0 <= mode <= 0xFF:
        raise ValueError(f"mode must fit in one byte, got {mode}")
    return (
        bytes([OP_IMAGE_HEADER])
        + len(data).to_bytes(4, "big")
        + bytes([slot, mode])
        + crc32(data).to_bytes(4, "big")
        + crc16(data).to_bytes(2, "big")
    )


def build_show_slot(slot: int) -> bytes:
    """Command that makes the panel display ``slot`` (like pressing the button)."""
    if slot not in USER_SLOTS:
        raise ValueError(f"slot must be 1-4, got {slot}")
    return bytes([OP_SHOW_SLOT, slot])


def _expect(op: int, data: bytes, min_len: int) -> None:
    if len(data) < min_len or data[0] != op:
        raise ProtocolError(f"expected opcode 0x{op:02x}, got {data.hex(' ')}")


def parse_battery(data: bytes) -> Battery:
    _expect(OP_BATTERY, data, 2)
    if data[1] == BATTERY_CHARGING:
        return Battery(level=None, charging=True)
    return Battery(level=data[1], charging=False)


def parse_slot(data: bytes) -> tuple[int, int]:
    """Return (currently displayed slot, CRC32 of its image)."""
    _expect(OP_GET_SLOT, data, 6)
    return data[1], int.from_bytes(data[2:6], "big")


def parse_device_info(data: bytes) -> DeviceInfo:
    _expect(OP_DEVICE_INFO, data, 7)
    mac = ":".join(f"{b:02X}" for b in data[1:7])
    serial = data[7:].decode("ascii", errors="replace")
    return DeviceInfo(mac=mac, serial=serial)


def chunks(data: bytes, size: int) -> Iterator[bytes]:
    if size <= 0:
        raise ValueError("chunk size must be positive")
    for i in range(0, len(data), size):
        yield data[i : i + size]
