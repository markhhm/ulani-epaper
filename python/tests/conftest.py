import bleak
import pytest
from PIL import Image

from ulani_epaper import cli, strings


@pytest.fixture(autouse=True)
def restore_pillow_pixel_cap(monkeypatch):
    """cli.main()/gui.main() raise Pillow's process-global pixel cap; undo it after each test."""
    monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", Image.MAX_IMAGE_PIXELS)


@pytest.fixture(autouse=True)
def no_real_bluetooth(monkeypatch):
    """Fail loudly if any test reaches real Bluetooth.

    A device may be bonded and in range while the suite runs; a regression
    in --dry-run handling must not scan for it or upload to it.
    """

    def bomb(*args, **kwargs):
        raise AssertionError("test tried to use real Bluetooth")

    monkeypatch.setattr(bleak, "BleakScanner", bomb)
    monkeypatch.setattr(bleak, "BleakClient", bomb)
    monkeypatch.setattr(cli, "connect", bomb)
    monkeypatch.setattr(cli, "scan", bomb)


@pytest.fixture(autouse=True)
def no_real_network(monkeypatch):
    """Fail loudly if any test makes a real HTTP request (calendar feeds are
    fetched with urllib; a fake bound too early once let a test reach the web)."""
    import urllib.request

    def bomb(*args, **kwargs):
        raise AssertionError("test tried to use the network")

    monkeypatch.setattr(urllib.request, "urlopen", bomb)
    monkeypatch.setattr(urllib.request.OpenerDirector, "open", bomb)  # build_opener(...).open too


@pytest.fixture(autouse=True)
def private_settings(monkeypatch, tmp_path_factory):
    """Settings and the sync log go to a temporary folder, never the user's."""
    monkeypatch.setenv("ULANI_CONFIG_DIR", str(tmp_path_factory.mktemp("config")))


@pytest.fixture(autouse=True)
def no_real_credential_store(monkeypatch):
    """The OS credential store (where the calendar addresses live) is replaced by
    a dict, so no test can read or overwrite the owner's real sign-in."""
    try:
        import keyring
    except ModuleNotFoundError:
        return
    store = {}
    monkeypatch.setattr(keyring, "get_password", lambda svc, user: store.get((svc, user)))
    monkeypatch.setattr(keyring, "set_password", lambda svc, user, pw: store.__setitem__((svc, user), pw))
    monkeypatch.setattr(keyring, "delete_password", lambda svc, user: store.pop((svc, user)))


@pytest.fixture(autouse=True)
def chinese_ui(monkeypatch):
    """The suite checks the Chinese texts: the system language is Chinese, and a test that
    switches the language does not leak it into the next one."""
    monkeypatch.setattr(strings, "system_language", lambda: "zh")
    strings.set_language("zh")
    yield
    strings.set_language("zh")
