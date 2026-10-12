"""Generate the Android splash images from the Paperhue master icon.

Usage (with Pillow installed):

    python web/scripts/gen_android_icons.py [--master PATH]

``--master`` defaults to ``shared/brand/paperhue-1024.png`` in the repository:
the 1024 x 1024 Paperhue icon (the rounded tile, transparent corners).

Writes, under web/android/app/src/main/res/, every existing
``drawable*/splash.png`` again at its own size: the master centred on the tile
colour, covering ``SPLASH_ICON_SHARE`` of the shorter side. The tile colour is
read from ``values/ic_launcher_background.xml``, which also colours the
Android 12+ system splash screen (``windowSplashScreenBackground`` in
``values/styles.xml``), so both stay the same colour. It is the bottom colour
of the launcher tile's gradient.

The launcher icons (``mipmap-*/ic_launcher*.png``, including the adaptive
icon's gradient background layer ``ic_launcher_background.png``, and
``mipmap-anydpi-v26/*.xml``) are not generated here. They are copied from the
Paperhue icon set, which draws each size at its own optical size and draws the
adaptive icon's background, foreground and monochrome layers apart from one
another; none of them can be recovered from the flattened master.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image

WEB = Path(__file__).resolve().parent.parent
REPO = WEB.parent
MASTER = REPO / "shared" / "brand" / "paperhue-1024.png"
RES = WEB / "android" / "app" / "src" / "main" / "res"
COLOUR_XML = RES / "values" / "ic_launcher_background.xml"

#: Share of the shorter splash side the icon covers.
SPLASH_ICON_SHARE = 0.4


def tile_colour() -> tuple[int, int, int]:
    """The ``ic_launcher_background`` colour (``#RRGGBB``) from values/."""
    text = COLOUR_XML.read_text(encoding="utf-8")
    match = re.search(r'<color name="ic_launcher_background">#([0-9A-Fa-f]{6})</color>', text)
    if match is None:
        raise SystemExit(f"{COLOUR_XML}: no #RRGGBB colour named ic_launcher_background")
    value = match.group(1)
    return int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)


def resized(image: Image.Image, size: int) -> Image.Image:
    """`image` scaled to `size` px square, with premultiplied alpha so the
    transparent corners leave no dark fringe."""
    return image.convert("RGBa").resize((size, size), Image.Resampling.LANCZOS).convert("RGBA")


def splash(master: Image.Image, width: int, height: int, colour: tuple[int, int, int]) -> Image.Image:
    canvas = Image.new("RGBA", (width, height), colour + (255,))
    size = round(min(width, height) * SPLASH_ICON_SHARE)
    canvas.alpha_composite(resized(master, size), ((width - size) // 2, (height - size) // 2))
    return canvas.convert("RGB")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--master", type=Path, default=MASTER,
                        help=f"the 1024 px master icon (default: {MASTER.relative_to(REPO).as_posix()})")
    args = parser.parse_args(argv)

    if not RES.is_dir():
        print(f"{RES} does not exist: run `npx cap add android` first", file=sys.stderr)
        return 1
    if not args.master.is_file():
        print(f"{args.master} does not exist: pass the master icon with --master", file=sys.stderr)
        return 1
    with Image.open(args.master) as opened:
        master = opened.convert("RGBA")
    if master.width != master.height:
        print(f"{args.master} is {master.width}x{master.height}, not square", file=sys.stderr)
        return 1
    colour = tile_colour()

    splashes = sorted(RES.glob("drawable*/splash.png"))
    if not splashes:
        print(f"no drawable*/splash.png under {RES}", file=sys.stderr)
        return 1
    for path in splashes:
        with Image.open(path) as old:
            width, height = old.size
        splash(master, width, height, colour).save(path, format="PNG", optimize=True)
        print(f"{path.relative_to(WEB).as_posix()}  {width}x{height}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
