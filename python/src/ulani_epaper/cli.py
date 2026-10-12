"""Command line interface: ``ulani scan | info | show | send | push | text | preview``."""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time

from PIL import Image

from bleak.exc import BleakError

from . import image, push
from .client import PushEvent, UploadResult, UlaniError, connect, scan
from .protocol import USER_SLOTS


def slot_arg(text: str) -> int:
    try:
        slot = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"page must be 1-4, got {text!r}") from None
    if slot not in USER_SLOTS:
        raise argparse.ArgumentTypeError(f"page must be 1-4, got {slot}")
    return slot


def _progress(sent: int, total: int) -> None:
    width = 30
    filled = width * sent // total
    sys.stderr.write(f"\r  [{'#' * filled}{'.' * (width - filled)}] {sent * 100 // total:3d}%")
    if sent == total:
        sys.stderr.write("\n")
    sys.stderr.flush()


async def _cmd_scan(args) -> int:
    devices = await scan(args.timeout)
    if not devices:
        print("No e-paper device found.")
        return 1
    for address, name, rssi in devices:
        print(f"{address}  {rssi:4d} dBm  {name}")
    return 0


async def _cmd_info(args) -> int:
    async with connect(args.address) as cal:
        info = await cal.device_info()
        battery = await cal.battery()
        slot, crc = await cal.current_slot()
        print(f"model      {await cal.model()}")
        print(f"firmware   {await cal.firmware()}")
        print(f"serial     {info.serial}")
        print(f"mac        {info.mac}")
        print(f"battery    {'charging' if battery.charging else f'{battery.level}/5'}")
        print(f"showing    page {slot} (image crc32 {crc:08x})")
    return 0


async def _cmd_show(args) -> int:
    async with connect(args.address) as cal:
        await cal.show(args.slot)
    print(f"switched to page {args.slot}")
    return 0


def _save(img: Image.Image, path: str) -> None:
    try:
        img.save(path)
    except ValueError as e:  # Pillow: unknown file extension
        raise UlaniError(f"cannot save {path}: {e}") from None


async def _upload(args, frame: bytes) -> int:
    if args.save_preview:
        _save(image.preview(frame), args.save_preview)
        print(f"preview saved to {args.save_preview}")
    if args.dry_run:
        return 0
    async with connect(args.address, flush_every=args.flush_every, chunk_delay=args.chunk_delay) as cal:
        shown, _ = await cal.current_slot()
        print(f"uploading {len(frame)} bytes to page {args.slot} (chunk {cal.chunk_size} B)")
        started = time.monotonic()
        bar_open = False

        def progress(sent: int, total: int) -> None:
            nonlocal bar_open
            _progress(sent, total)
            bar_open = sent < total

        try:
            result = await cal.upload(frame, args.slot, progress=progress)
        finally:
            if bar_open:  # upload stopped early: end the bar's line before any error
                sys.stderr.write("\n")
    elapsed = time.monotonic() - started
    if result is UploadResult.UNCHANGED:
        print(f"page {args.slot} already holds this exact image; nothing sent "
              f"(run 'ulani show {args.slot}' to display it)")
    elif args.slot == shown:
        print(f"done in {elapsed:.1f}s - the panel is refreshing now (~40s); the device "
              "does not respond until it has finished")
    else:
        print(f"done in {elapsed:.1f}s - page {args.slot} is not on screen; "
              f"run 'ulani show {args.slot}' to display it")
    return 0


async def _cmd_push(args) -> int:
    try:
        frames = push.prepare(args.images, fit=args.fit, dither=not args.no_dither)
    except ValueError as e:
        raise UlaniError(str(e)) from None
    if args.save_preview:
        os.makedirs(args.save_preview, exist_ok=True)
        for slot, frame in sorted(frames.items()):
            _save(image.preview(frame), os.path.join(args.save_preview, f"page{slot}.png"))
        print(f"previews saved to {args.save_preview}")
    if args.dry_run:
        return 0

    started = time.monotonic()
    bar_open = False

    def on_event(e: PushEvent) -> None:
        nonlocal bar_open
        if e.phase == "start":
            print(f"page {e.slot} ({e.index + 1}/{e.count})")
        elif e.phase == "sending":
            _progress(e.sent, e.total)
            bar_open = e.sent < e.total
        elif e.phase == "unchanged":
            print(f"  page {e.slot} already holds this image; skipped")
        elif e.phase == "refreshing":
            print(f"  page {e.slot} is on screen: the panel refreshes now (~40s)")

    try:
        results = await push.push_frames(frames, address=args.address, progress=on_event,
                                         flush_every=args.flush_every, chunk_delay=args.chunk_delay)
    finally:
        if bar_open:
            sys.stderr.write("\n")
    sent = sum(r is UploadResult.OK for r in results.values())
    print(f"done in {time.monotonic() - started:.0f}s: {sent} page(s) uploaded, "
          f"{len(results) - sent} unchanged")
    return 0


async def _cmd_send(args) -> int:
    with image.open_image(args.image) as src:
        frame = image.encode(src, fit_mode=args.fit, dither=not args.no_dither)
    return await _upload(args, frame)


async def _cmd_text(args) -> int:
    text = args.text.replace("\\n", "\n")
    page = image.render_text(text, colour=args.colour, background=args.background, font_path=args.font)
    return await _upload(args, image.encode(page, dither=False))


def _cmd_preview(args) -> int:
    with image.open_image(args.image) as src:
        frame = image.encode(src, fit_mode=args.fit, dither=not args.no_dither)
    _save(image.preview(frame), args.output)
    print(f"preview saved to {args.output}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    address_help = "BLE address from 'ulani scan' (default: first device found)"
    parser = argparse.ArgumentParser(prog="ulani", description="Control a ULANI e-paper device over BLE.")
    parser.add_argument("-a", "--address", help=address_help)
    # Also accept -a after the command; SUPPRESS keeps a value given before it.
    device = argparse.ArgumentParser(add_help=False)
    device.add_argument("-a", "--address", default=argparse.SUPPRESS, help=address_help)
    sub = parser.add_subparsers(dest="command", required=True)

    s = sub.add_parser("scan", help="list devices in range")
    s.add_argument("-t", "--timeout", type=float, default=20.0,
                   help="seconds (default: %(default)s); the device advertises only sparsely")

    sub.add_parser("info", parents=[device], help="show model, firmware, serial, MAC, battery and current page")

    s = sub.add_parser("show", parents=[device], help="switch the page on screen (like pressing the button)")
    s.add_argument("slot", type=slot_arg, help="page 1-4")

    def pacing_opts(p):
        p.add_argument("--flush-every", type=int, default=10, metavar="N",
                       help="wait for the BLE queue to drain every N packets (0 = never)")
        p.add_argument("--chunk-delay", type=float, default=0.0, metavar="SEC",
                       help="extra pause between packets, e.g. 0.06 if uploads still fail")

    def upload_opts(p):
        p.add_argument("-s", "--slot", type=slot_arg, required=True,
                       help="page 1-4 (the button cycles through them)")
        p.add_argument("--save-preview", metavar="PNG", help="also save what the panel will show")
        p.add_argument("--dry-run", action="store_true", help="convert only, do not connect")
        pacing_opts(p)

    def convert_opts(p, fit="contain"):
        p.add_argument("--fit", choices=["contain", "cover", "stretch"], default=fit,
                       help="contain = whole image with white bars, cover = fill and crop (default: %(default)s)")
        p.add_argument("--no-dither", action="store_true", help="nearest colour instead of dithering")

    s = sub.add_parser("send", parents=[device], help="upload an image file")
    s.add_argument("image")
    convert_opts(s)
    upload_opts(s)

    s = sub.add_parser("push", parents=[device],
                       help="upload up to four photos to pages 1-4 in one go (page on screen last)")
    s.add_argument("images", nargs="+", metavar="IMAGE", help="1-4 images; the n-th goes to page n")
    convert_opts(s, fit="cover")
    s.add_argument("--save-preview", metavar="DIR", help="also save page1.png ... to this folder")
    s.add_argument("--dry-run", action="store_true", help="convert only, do not connect")
    pacing_opts(s)

    colours = [c.name for c in image.PALETTE]
    s = sub.add_parser("text", parents=[device], help="render text and upload it")
    s.add_argument("text", help="use \\n for line breaks")
    s.add_argument("--colour", choices=colours, default="black")
    s.add_argument("--background", choices=colours, default="white")
    s.add_argument("--font", help="path to a .ttf/.ttc font")
    upload_opts(s)

    s = sub.add_parser("preview", help="convert an image and save how it will look (offline)")
    s.add_argument("image")
    s.add_argument("-o", "--output", required=True)
    convert_opts(s)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    Image.MAX_IMAGE_PIXELS = image.MAX_PHOTO_PIXELS  # the user's own photos (200 MP phones)
    try:
        if args.command == "preview":
            return _cmd_preview(args)
        handler = {"scan": _cmd_scan, "info": _cmd_info, "show": _cmd_show,
                   "send": _cmd_send, "push": _cmd_push, "text": _cmd_text}[args.command]
        return asyncio.run(handler(args))
    # OSError covers missing/unreadable files, PIL.UnidentifiedImageError,
    # bad fonts and WinRT link errors; asyncio.TimeoutError differs from the
    # builtin TimeoutError before Python 3.11.
    except (UlaniError, BleakError, OSError, asyncio.TimeoutError) as e:
        print(f"error: {str(e) or type(e).__name__}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
