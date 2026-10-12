import pytest

from ulani_epaper import protocol as p


def test_crc16_is_xmodem():
    assert p.crc16(b"123456789") == 0x31C3


def test_crc32_is_standard_zlib():
    assert p.crc32(b"123456789") == 0xCBF43926


def test_image_header_layout():
    header = p.build_image_header(b"123456789", slot=2, mode=1)
    assert header == bytes.fromhex("01" "00000009" "02" "01" "CBF43926" "31C3")
    assert len(header) == 13


@pytest.mark.parametrize("slot", [-1, 256])
def test_image_header_rejects_bad_slot(slot):
    with pytest.raises(ValueError):
        p.build_image_header(b"x", slot=slot)


def test_frame_size_matches_panel():
    assert p.FRAME_BYTES == 800 * 480 // 2 == 192_000


def test_parse_battery_levels_and_charging():
    assert p.parse_battery(bytes([0x06, 0x03])) == p.Battery(level=3, charging=False)
    assert p.parse_battery(bytes([0x06, 0x06])) == p.Battery(level=None, charging=True)


def test_parse_battery_rejects_other_opcode():
    with pytest.raises(p.ProtocolError):
        p.parse_battery(bytes([0x0C, 0x01]))


def test_parse_slot():
    assert p.parse_slot(bytes.fromhex("0c022b9f7a43")) == (2, 0x2B9F7A43)


def test_parse_device_info():
    raw = bytes.fromhex("0a112233445566") + b"UP7320EXX0000000"
    info = p.parse_device_info(raw)
    assert info.mac == "11:22:33:44:55:66"
    assert info.serial == "UP7320EXX0000000"


def test_show_slot_command():
    assert p.build_show_slot(2) == bytes([0x0B, 0x02])


@pytest.mark.parametrize("slot", [0, 5, 16])
def test_show_slot_rejects_non_user_slots(slot):
    with pytest.raises(ValueError):
        p.build_show_slot(slot)


def test_chunks():
    assert list(p.chunks(b"abcdefg", 3)) == [b"abc", b"def", b"g"]


def test_chunks_rejects_non_positive_size():
    with pytest.raises(ValueError):
        list(p.chunks(b"abc", 0))
