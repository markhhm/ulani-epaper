import bleak
import pytest
from PIL import Image

from ulani_epaper import cli


@pytest.fixture(autouse=True)
def restore_pillow_pixel_cap(monkeypatch):
    """cli.main()/gui.main() raise Pillow's process-global pixel cap; undo it after each test."""
    monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", Image.MAX_IMAGE_PIXELS)


@pytest.fixture(autouse=True)
def no_real_bluetooth(monkeypatch):
    """Fail loudly if any test reaches real Bluetooth.

    A calendar may be bonded and in range while the suite runs; a regression
    in --dry-run handling must not scan for it or upload to it.
    """

    def bomb(*args, **kwargs):
        raise AssertionError("test tried to use real Bluetooth")

    monkeypatch.setattr(bleak, "BleakScanner", bomb)
    monkeypatch.setattr(bleak, "BleakClient", bomb)
    monkeypatch.setattr(cli, "connect", bomb)
    monkeypatch.setattr(cli, "scan", bomb)
