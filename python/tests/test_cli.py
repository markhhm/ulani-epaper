import argparse
import re

import pytest
from PIL import Image

from ulani_epaper import cli
from ulani_epaper.protocol import HEIGHT, IGNORED_SLOT, WIDTH


@pytest.mark.parametrize("text, slot", [("1", 1), ("4", 4)])
def test_slot_argument(text, slot):
    assert cli.slot_arg(text) == slot


# only pages 1-4 are offered (firmware v1.0.09 ignores other slots)
@pytest.mark.parametrize("text", ["0", "5", "abc", str(IGNORED_SLOT)])
def test_slot_argument_rejects(text):
    with pytest.raises(argparse.ArgumentTypeError):
        cli.slot_arg(text)


def test_show_command_requires_user_slot():
    with pytest.raises(SystemExit):
        cli.build_parser().parse_args(["show", "7"])
    assert cli.build_parser().parse_args(["show", "3"]).slot == 3


def test_preview_command_writes_png(tmp_path):
    src = tmp_path / "in.png"
    Image.new("RGB", (300, 200), (200, 30, 30)).save(src)
    out = tmp_path / "out.png"
    assert cli.main(["preview", str(src), "-o", str(out)]) == 0
    with Image.open(out) as img:
        assert img.size == (WIDTH, HEIGHT)


def test_send_dry_run_does_not_touch_bluetooth(tmp_path, monkeypatch):
    def boom(*a, **k):
        raise AssertionError("must not connect in dry-run")

    monkeypatch.setattr(cli, "connect", boom)
    src = tmp_path / "in.png"
    Image.new("RGB", (800, 480), "white").save(src)
    out = tmp_path / "p.png"
    assert cli.main(["send", str(src), "--slot", "1", "--dry-run", "--save-preview", str(out)]) == 0
    assert out.exists()


def test_text_dry_run(tmp_path):
    out = tmp_path / "t.png"
    assert cli.main(["text", "Hi", "--slot", "2", "--colour", "red", "--dry-run", "--save-preview", str(out)]) == 0
    assert out.exists()


def _image(tmp_path):
    src = tmp_path / "in.png"
    Image.new("RGB", (80, 48), "blue").save(src)
    return src


@pytest.mark.parametrize("argv", [
    lambda t: ["preview", str(t / "missing.png"), "-o", str(t / "o.png")],          # missing input
    lambda t: ["send", str(t / "notes.txt"), "--slot", "1", "--dry-run"],             # not an image
    lambda t: ["preview", str(_image(t)), "-o", str(t / "out.xyz")],                  # unknown extension
    lambda t: ["preview", str(_image(t)), "-o", str(t / "no" / "dir" / "o.png")],     # missing folder
    lambda t: ["text", "Hi", "--slot", "1", "--font", str(t / "nope.ttf"), "--dry-run"],  # bad font
])
def test_user_mistakes_are_one_line_errors(tmp_path, capsys, argv):
    (tmp_path / "notes.txt").write_text("not an image")
    assert cli.main(argv(tmp_path)) == 1
    err = capsys.readouterr().err
    assert err.startswith("error: ") and len(err.strip()) > len("error:")
    assert "Traceback" not in err


def test_cli_accepts_200_megapixel_photos_and_reports_broken_files_cleanly(tmp_path, capsys):
    from test_image import header_only_png

    path = header_only_png(tmp_path / "200mp.png", 16320, 12240)
    # the CLI raises Pillow's size cap for user-picked photos, so this header-only file now fails
    # while decoding (truncated), which must still be a one-line error
    assert cli.main(["push", str(path), "--dry-run"]) == 1
    err = capsys.readouterr().err
    assert err.startswith("error: ") and "Traceback" not in err and "decompression bomb" not in err


def test_message_less_errors_name_the_error_type(monkeypatch, capsys):
    async def fail(args):
        raise TimeoutError()

    monkeypatch.setattr(cli, "_cmd_info", fail)
    assert cli.main(["info"]) == 1
    assert capsys.readouterr().err.strip() == "error: TimeoutError"


@pytest.mark.parametrize("argv", [["-a", "AA:BB", "info"], ["info", "-a", "AA:BB"], ["send", "x.png", "-s", "1", "--address", "AA:BB"]])
def test_address_is_accepted_before_or_after_the_command(argv):
    assert cli.build_parser().parse_args(argv).address == "AA:BB"


def test_address_defaults_to_none():
    assert cli.build_parser().parse_args(["info"]).address is None


class _FakeCal:
    chunk_size = 230

    def __init__(self, shown, fail=False):
        self.shown, self.fail = shown, fail

    async def current_slot(self):
        return self.shown, 0

    async def upload(self, frame, slot, progress=None):
        from ulani_epaper.client import UploadFailed, UploadResult

        progress(100, len(frame))
        if self.fail:
            raise UploadFailed("device reported failure: 02 01")
        progress(len(frame), len(frame))
        return UploadResult.OK


def _fake_connect(cal):
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def connect(*a, **k):
        yield cal

    return connect


@pytest.mark.parametrize("shown, expected", [(2, "refreshing now (~40s); the device does not respond"),
                                             (3, "ulani show 2")])
def test_upload_message_depends_on_whether_the_page_is_on_screen(tmp_path, monkeypatch, capsys, shown, expected):
    monkeypatch.setattr(cli, "connect", _fake_connect(_FakeCal(shown)))
    assert cli.main(["send", str(_image(tmp_path)), "--slot", "2"]) == 0
    assert expected in capsys.readouterr().out


def test_failed_upload_error_starts_on_its_own_line(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(cli, "connect", _fake_connect(_FakeCal(1, fail=True)))
    assert cli.main(["send", str(_image(tmp_path)), "--slot", "2"]) == 1
    err = capsys.readouterr().err
    assert "\nerror: device reported failure" in err


def test_scan_without_results_says_no_device_found(monkeypatch, capsys):
    async def nothing(timeout):
        return []

    monkeypatch.setattr(cli, "scan", nothing)
    assert cli.main(["scan", "-t", "0.1"]) == 1
    assert capsys.readouterr().out.strip() == "No e-paper device found."


def test_help_calls_the_hardware_a_device(capsys):
    texts = [cli.build_parser().format_help()]
    for command in ("scan", "info", "push", "sync", "feeds", "schedule"):
        with pytest.raises(SystemExit):
            cli.build_parser().parse_args([command, "--help"])
        texts.append(capsys.readouterr().out)
    assert "ULANI e-paper device" in texts[0]
    assert "list devices in range" in texts[0]
    # "calendar" only names the calendar data (sources, pages), never the hardware
    data = re.compile(r"calendar(s\.md| sources| pages| and to-do pages)", re.I)
    assert all("calendar" not in data.sub("", " ".join(text.split())).lower() for text in texts)
