"""Command line interface: ``ulani scan | info | show | send | push | text | preview``
and, for the calendar pages, ``ulani pages | feeds | sync | schedule``."""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time

from PIL import Image

from bleak.exc import BleakError

from . import config, image, push, schedule, sync, syncjob
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


# --- calendar pages ------------------------------------------------------------

def _cmd_pages(args) -> int:
    settings = config.load()
    for item in args.assign:
        slot, sep, kind = item.partition("=")
        if not sep or not slot.strip().isdigit():
            raise UlaniError(f"expected PAGE=KIND such as 1=month, got {item!r}")
        settings.pages[int(slot)] = kind.strip()
    if args.assign:
        try:
            config.save(settings)
        except ValueError as e:
            raise UlaniError(str(e)) from None
    for slot, kind in sorted(settings.pages.items()):
        print(f"{slot}  {kind:<7} {config.PAGE_NAMES[kind]}")
    return 0


def _calendar_deps():
    """The feeds module, or a clear error if the optional packages are missing."""
    try:
        import icalendar  # noqa: F401
        import keyring  # noqa: F401
    except ModuleNotFoundError as e:
        raise UlaniError(f"the calendar pages need extra packages: pip install \"ulani-epaper[calendar]\" "
                         f"({e.name} is missing)") from None
    from . import feeds

    return feeds


def _ask_secret(prompt: str) -> str:
    import getpass

    return getpass.getpass(prompt)


def _feed_arg(settings: config.Settings, key: str) -> config.Feed:
    feed = settings.feed(key)
    if not feed:
        raise UlaniError(f"no calendar source {key!r} (see 'ulani feeds')")
    return feed


def _counts(parsed) -> str:
    return f"{len(parsed.events)} events in the coming weeks, {len(parsed.tasks)} open to-dos"


def _cmd_feeds(args) -> int:
    fd = _calendar_deps()
    settings, store = config.load(), fd.KeyringSecrets()
    action = args.action or "list"
    if action == "list":
        if not settings.feeds:
            print("no calendar sources yet: ulani feeds add NAME (see docs/CALENDARS.md)")
            return 1
        for f in settings.feeds:
            info = store.get(f.id)
            host = fd.where(info["url"]) if info and info.get("url") else "(address missing: add it again)"
            print(f"{f.id}  {f.name:<10} {f.color or 'auto':<8} {host}")
        return 0
    if action == "add":
        if "://" in args.name or args.name.lower().startswith(("http", "webcal")):
            raise UlaniError("the first argument is the source's name, e.g. ulani feeds add 個人 "
                             "(then paste the address when asked)")
        url = args.url or _ask_secret("Paste the calendar's iCal (.ics) address (not shown): ")
        password = _ask_secret(f"Password for {args.user} (not shown): ") if args.user else ""
        url = fd.normalize_url(url)
        if not args.no_check:
            print(f"checking {fd.where(url)} ...")
            print(f"ok: {_counts(fd.probe(url, args.user or '', password))}")
        try:
            feed = fd.new_feed(settings, args.name, url, args.color or "", args.user or "", password, store)
        except ValueError as e:
            raise UlaniError(str(e)) from None
        config.save(settings)
        print(f"added {feed.name} ({feed.id}); the address is kept in the OS credential store")
    elif action == "remove":
        feed = _feed_arg(settings, args.feed)
        fd.remove_feed(settings, feed, store)
        config.save(settings)
        print(f"removed {feed.name}")
    elif action == "edit":
        feed = _feed_arg(settings, args.feed)
        if args.name:
            feed.name = args.name.strip()
        if args.color is not None:
            feed.color = "" if args.color == "auto" else args.color
        try:
            settings.validate()
        except ValueError as e:
            raise UlaniError(str(e)) from None
        if args.url:
            url = fd.normalize_url(_ask_secret("Paste the new iCal (.ics) address (not shown): "))
            user, password = fd.login_for(store.get(feed.id), url)  # another host: no old password
            print(f"ok: {_counts(fd.probe(url, user, password))}")
            store.set(feed.id, url, user, password)
        config.save(settings)
        print(f"updated {feed.name}")
    elif action == "test":
        failed = 0
        for f in settings.feeds:
            info = store.get(f.id) or {}
            try:
                if not info.get("url"):
                    raise fd.FeedError("找不到這個來源的網址，請重新加入")
                print(f"{f.name}: {_counts(fd.probe(info['url'], info.get('user', ''), info.get('password', '')))}")
            except fd.FeedError as e:
                failed += 1
                print(f"{f.name}: FAILED - {e}")
        return 1 if failed or not settings.feeds else 0
    return 0


async def _cmd_sync(args) -> int:
    _calendar_deps()
    settings = config.load()
    if args.address:
        settings.address = args.address

    def on_event(e: PushEvent) -> None:
        if e.phase == "start":
            print(f"page {e.slot} ({e.index + 1}/{e.count})")
        elif e.phase == "refreshing":
            print(f"  page {e.slot} is on screen: the panel refreshes now (~40s)")

    report = await sync.sync(settings, dry_run=args.dry_run, progress=on_event,
                             flush_every=args.flush_every, chunk_delay=args.chunk_delay)
    print(syncjob.describe(report))
    return 0


SELFTEST_ICS = (b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a\r\nSUMMARY:\xe6\xb8\xac\xe8\xa9\xa6\r\n"
                b"DTSTART;TZID=Asia/Taipei:20261012T090000\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY;COUNT=3\r\n"
                b"END:VEVENT\r\nBEGIN:VTODO\r\nUID:b\r\nSUMMARY:x\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")


def _cmd_selftest(args) -> int:
    """Check the installation without Bluetooth or network (the Windows build runs it)."""
    from datetime import date, datetime, timedelta, timezone

    failed = 0

    def check(name: str, fn) -> None:
        nonlocal failed
        try:
            print(f"{name}: {fn()}")
        except Exception as e:  # reported, then the exit code says it failed
            failed += 1
            print(f"{name}: FAILED - {type(e).__name__}: {e}")

    def keyring_backend() -> str:
        _calendar_deps()
        import keyring

        backend = type(keyring.get_keyring())
        name = f"{backend.__module__}.{backend.__name__}"
        if sys.platform == "win32" and "Windows" not in name:
            raise UlaniError(f"no Windows credential store, got {name}")
        return name

    def ical_sample() -> str:
        from . import ical

        tz = timezone(timedelta(hours=8))
        feed = ical.parse(SELFTEST_ICS, datetime(2026, 10, 1, tzinfo=tz), datetime(2026, 11, 1, tzinfo=tz), tz)
        if len(feed.events) != 3 or len(feed.tasks) != 1:
            raise UlaniError(f"expected 3 events and 1 to-do, got {len(feed.events)} and {len(feed.tasks)}")
        return "3 events, 1 to-do"

    def page(kind: str):
        def draw() -> str:
            from . import layouts
            from .agenda import LOCAL, AgendaData

            img = layouts.RENDERERS[kind](AgendaData(), date.today(), LOCAL)
            colours = {c for _, c in img.getcolors(1 << 20)} - {c.rgb for c in image.PALETTE}
            if img.size != (800, 480) or colours:
                raise UlaniError(f"bad drawing {img.size} {sorted(colours)[:3]}")
            return "drawn"
        return draw

    check("credential store", keyring_backend)
    check("ical", ical_sample)
    for kind in ("month", "agenda", "todo"):
        check(kind, page(kind))
    print("FAILED" if failed else "ok")
    return 1 if failed else 0


def _cmd_schedule(args) -> int:
    if args.action == "install":
        settings = config.load()
        if args.times:
            settings.times = args.times
        try:
            config.save(settings)
        except ValueError as e:
            raise UlaniError(str(e)) from None
        schedule.install(settings.times)
        print(f"the calendar pages will update daily at {', '.join(settings.times)} "
              "(while you are signed in to Windows)")
    elif args.action == "remove":
        print("scheduled sync removed" if schedule.remove() else "there was no scheduled sync")
    else:
        st = schedule.status()
        if not st:
            print("not scheduled (ulani schedule install)")
            return 1
        print(f"daily at {', '.join(st['times'])}: {st['command']} {st['arguments']}")
        last = syncjob.last()
        if last:
            print(f"last run {last['time']}: {'ok' if last['ok'] else 'FAILED'} - {last['message']}")
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

    s = sub.add_parser("pages", help="show or set what each page shows: photo, month, agenda, todo")
    s.add_argument("assign", nargs="*", metavar="PAGE=KIND", help="e.g. 1=month 2=agenda 3=todo 4=photo")

    colour_help = f"one of {', '.join(config.FEED_COLOURS)}, #rrggbb, or auto"
    f = sub.add_parser("feeds", help="calendar sources: iCal (.ics) addresses (see docs/CALENDARS.md)")
    fsub = f.add_subparsers(dest="action")
    fsub.add_parser("list", help="list the sources (default)")
    s = fsub.add_parser("add", help="add a source; without URL the address is asked for (not shown, not in history)")
    s.add_argument("name", help="shown on the pages, e.g. 個人 or 學校")
    s.add_argument("url", nargs="?", help="the .ics / webcal address (better: leave it out and paste when asked)")
    s.add_argument("--color", help=colour_help)
    s.add_argument("--user", help="user name, for addresses that need a login (e.g. Nextcloud app password)")
    s.add_argument("--no-check", action="store_true", help="save without downloading it once")
    s = fsub.add_parser("remove", help="remove a source and its stored address")
    s.add_argument("feed", metavar="NAME_OR_ID")
    s = fsub.add_parser("edit", help="rename, recolour or replace the address of a source")
    s.add_argument("feed", metavar="NAME_OR_ID")
    s.add_argument("--name")
    s.add_argument("--color", help=colour_help)
    s.add_argument("--url", action="store_true", help="ask for a new address")
    fsub.add_parser("test", help="download every source now and report what it contains")

    s = sub.add_parser("sync", parents=[device], help="update the calendar and to-do pages from the feeds now")
    s.add_argument("--dry-run", action="store_true", help="fetch and draw only, do not connect")
    pacing_opts(s)

    sub.add_parser("selftest", help="check the installation: fonts, calendar pages, iCal, credential store")

    s = sub.add_parser("schedule", help="update the pages daily at fixed times (Windows)")
    ssub = s.add_subparsers(dest="action", required=True)
    s = ssub.add_parser("install", help="create or update the scheduled task")
    s.add_argument("--times", nargs="+", metavar="HH:MM", help="default: the saved times (06:00 12:00 18:00)")
    ssub.add_parser("remove", help="delete the scheduled task")
    ssub.add_parser("status", help="show the schedule and the last run")
    return parser


def main(argv: list[str] | None = None) -> int:
    if (sys.argv[1:] if argv is None else argv)[:1] == ["--sync"]:  # the scheduled task (see schedule.py)
        return syncjob.main()
    args = build_parser().parse_args(argv)
    Image.MAX_IMAGE_PIXELS = image.MAX_PHOTO_PIXELS  # the user's own photos (200 MP phones)
    for stream in (sys.stdout, sys.stderr):  # Chinese names piped out on e.g. a cp1252 system
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    try:
        plain = {"preview": _cmd_preview, "pages": _cmd_pages, "feeds": _cmd_feeds, "schedule": _cmd_schedule,
                 "selftest": _cmd_selftest}
        if args.command in plain:
            return plain[args.command](args)
        handler = {"scan": _cmd_scan, "info": _cmd_info, "show": _cmd_show, "send": _cmd_send,
                   "push": _cmd_push, "text": _cmd_text, "sync": _cmd_sync}[args.command]
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
