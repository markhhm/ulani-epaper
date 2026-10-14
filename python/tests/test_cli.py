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


def test_cli_too_large_photo_is_an_error(tmp_path, capsys):
    from test_image import header_only_png

    path = header_only_png(tmp_path / "200mp.png", 16320, 12240)  # a 200 MP phone photo
    for argv in (["push", str(path), "--dry-run"], ["preview", str(path), "-o", str(tmp_path / "o.png")]):
        assert cli.main(argv) == 1
        err = capsys.readouterr().err
        assert err == "error: the photo is over the 50 megapixel limit; shrink it first\n"


def test_cli_reports_a_truncated_photo_cleanly(tmp_path, capsys):
    from test_image import header_only_png

    path = header_only_png(tmp_path / "cut.png", 800, 600)  # the header only: decoding fails
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


# --- --crop ---------------------------------------------------------------------

CROP = (0.1, 0.2, 0.5, 0.4)  # 600 x 360 px of a 1200 x 900 photo: 5:3


def _patterned(tmp_path):
    src = tmp_path / "pattern.png"
    img = Image.new("RGB", (1200, 900), "white")
    img.paste((200, 0, 0), (0, 0, 600, 450))
    img.paste((0, 0, 200), (600, 450, 1200, 900))
    img.save(src)
    return src


def _expected(src, crop=None):
    from ulani_epaper import image

    with image.open_image(src) as img:
        return image.preview(image.encode(img, "cover", dither=False, crop=crop)).tobytes()


def _saved(path):
    with Image.open(path) as img:
        return img.convert("RGB").tobytes()


def test_parse_crop_ok_and_errors():
    assert cli.parse_crop("0.1, 0.2,0.5 ,0.4") == CROP
    assert cli.parse_page_crop("2=0,0,1,0.5") == (2, (0.0, 0.0, 1.0, 0.5))
    for bad in ["", "1,2,3", "1,2,3,4,5", "a,b,c,d", "nan,0,1,1"]:
        with pytest.raises(argparse.ArgumentTypeError, match="expected LEFT,TOP,WIDTH,HEIGHT as fractions 0-1"):
            cli.parse_crop(bad)
    for bad in ["0.1,0.2,0.5,0.4", "5=0,0,1,1", "x=0,0,1,1"]:
        with pytest.raises(argparse.ArgumentTypeError):
            cli.parse_page_crop(bad)


def test_send_with_crop_uses_it(tmp_path):
    src, out = _patterned(tmp_path), tmp_path / "p.png"
    argv = ["send", str(src), "--slot", "1", "--dry-run", "--no-dither", "--save-preview", str(out)]
    assert cli.main(argv + ["--crop", "0.1,0.2,0.5,0.4"]) == 0  # a crop means Fill
    assert _saved(out) == _expected(src, CROP) != _expected(src)


def test_push_crop_per_page(tmp_path):
    src, other, out = _patterned(tmp_path), _patterned(tmp_path), tmp_path / "previews"
    assert cli.main(["push", str(src), str(other), "--crop", "2=0.1,0.2,0.5,0.4", "--dry-run",
                     "--no-dither", "--save-preview", str(out)]) == 0
    assert _saved(out / "page1.png") == _expected(src)
    assert _saved(out / "page2.png") == _expected(other, CROP)


@pytest.mark.parametrize("argv", [
    ["send", "{src}", "--slot", "1", "--dry-run", "--crop", "0,0,1,1"],           # not 5:3 for this photo
    ["send", "{src}", "--slot", "1", "--dry-run", "--crop", "0.5,0,0.8,0.64"],    # sticks out of the photo
    ["send", "{src}", "--slot", "1", "--dry-run", "--fit", "contain", "--crop", "0.1,0.2,0.5,0.4"],
    ["push", "{src}", "--dry-run", "--crop", "2=0.1,0.2,0.5,0.4"],                # no second photo
    ["push", "{src}", "--dry-run", "--fit", "contain", "--crop", "1=0.1,0.2,0.5,0.4"],
])
def test_bad_crop_is_a_clear_error(tmp_path, capsys, argv):
    src = _patterned(tmp_path)
    assert cli.main([a.replace("{src}", str(src)) for a in argv]) == 1
    err = capsys.readouterr().err
    assert err.startswith("error: ") and "crop" in err and "Traceback" not in err


@pytest.mark.parametrize("argv", [
    ["send", "a.jpg", "-s", "1"], ["push", "a.jpg", "b.jpg"], ["preview", "a.jpg", "-o", "o.png"],
])
def test_every_command_that_dithers_a_photo_takes_the_colours(argv):
    parser = cli.build_parser()
    assert parser.parse_args(argv).colours == "natural"
    assert parser.parse_args(argv + ["--colours", "classic"]).colours == "classic"
    with pytest.raises(SystemExit):
        parser.parse_args(argv + ["--colours", "vivid"])


def test_the_colours_reach_the_dithering(tmp_path, monkeypatch):
    from ulani_epaper import image

    chosen, real = [], image.encode
    monkeypatch.setattr(image, "encode", lambda *a, **kw: chosen.append(kw.get("colours")) or real(*a, **kw))
    monkeypatch.setattr(image, "natural", lambda img, strength=1.0: bytes(WIDTH * HEIGHT))  # quick stand-ins
    monkeypatch.setattr(image, "stucki", lambda img, strength=1.0: bytes([1]) * (WIDTH * HEIGHT))
    src, out = str(_image(tmp_path)), tmp_path / "o.png"
    assert cli.main(["preview", src, "-o", str(out), "--colours", "classic"]) == 0
    with Image.open(out) as img:
        assert img.getpixel((0, 0)) == image.PANEL_RGB[1]  # Classic's stand-in: white, drawn in the panel's white
    assert cli.main(["send", src, "-s", "1", "--dry-run", "--colours", "classic"]) == 0
    assert cli.main(["push", src, "--dry-run", "--colours", "classic"]) == 0
    assert cli.main(["preview", src, "-o", str(out)]) == 0
    with Image.open(out) as img:
        assert img.getpixel((0, 0)) == image.PANEL_RGB[0]  # Natural's stand-in: black, in the panel's black
    assert chosen == ["classic", "classic", "classic", "natural"]
