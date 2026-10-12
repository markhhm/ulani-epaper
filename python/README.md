# ulani-epaper: the Python library behind Paperhue

Developer guide for the `ulani-epaper` package: the Python library, the
`ulani` command-line tool and the Paperhue desktop app for ULANI 7-colour
e-paper devices (ULANI 永恆曆). If you only want to put photos on your
device, download Paperhue.exe as described in the
[main README](../README.md).

| Module | What it does |
|---|---|
| `ulani_epaper.push` | one-call API: `push_images`, `prepare`, `push_frames` |
| `ulani_epaper.client` | Bluetooth session: `connect`, `scan`, `find`, `Calendar` |
| `ulani_epaper.image` | image to 4-bit, 7-colour frame: `open_image`, `encode`, `preview`, `render_text`, `PALETTE` |
| `ulani_epaper.protocol` | byte layouts, checksums and reply parsing (no I/O) |
| `ulani_epaper.cli` | the `ulani` command |
| `ulani_epaper.gui` | the Paperhue desktop app (tkinter) |
| `ulani_epaper.config` | settings: what each page shows, calendar sources (names and colours), sync times |
| `ulani_epaper.feeds`, `ulani_epaper.ical` | calendar sources: download iCal addresses (kept in the OS credential store) and read events and to-dos, recurrences expanded |
| `ulani_epaper.agenda`, `ulani_epaper.layouts`, `ulani_epaper.fonts` | the data model and the month, week agenda and to-do pages, drawn with the bundled Noto Sans CJK TC subset |
| `ulani_epaper.sync`, `ulani_epaper.syncjob`, `ulani_epaper.schedule` | one sync (feeds to pages to device, in memory), the scheduled run and its log, the Windows Task Scheduler task |
| `ulani_epaper.relay`, `ulani_epaper.vectors` | tools for the Swift code in `apple/`: a Bluetooth-over-TCP relay with a simulated device (`--fake`), and the generator for `shared/vectors/` |

The Bluetooth protocol is described in
[shared/PROTOCOL.md](../shared/PROTOCOL.md); the calendar pages in
[shared/LAYOUTS.md](../shared/LAYOUTS.md) (layout spec) and
[shared/AGENDA.md](../shared/AGENDA.md) (data model, iCal rules, vectors).
The user guide for calendar sources is [docs/CALENDARS.md](../docs/CALENDARS.md).

## Requirements

- Python 3.10–3.14 and a Bluetooth LE adapter. Dependencies: `bleak` and
  `Pillow`; the calendar pages also need the `calendar` extra (`icalendar`
  and `keyring`).
- Tested with a real device on Windows 11 only.
- Python 3.15 does not work on Windows yet: as of 2026-10, the `winrt-*`
  packages `bleak` needs there have no 3.15 wheels, so pip asks for a C++
  compiler. Use `py -3.14` (`py --list` shows what is installed).
- The device must be paired with the computer once, in the OS Bluetooth
  settings, while it is in pairing mode (hold its button about 5 s until the
  LED blinks green). Unpaired access fails with *Insufficient
  Authentication*.

## Install

```
pip install "ulani-epaper @ git+https://github.com/markhhm/ulani-epaper#subdirectory=python"
```

This installs the library, the `ulani` command and the `paperhue` command
(the desktop app; it takes up to four image paths for the photo pages). For
the calendar pages, install the extra:

```
pip install "ulani-epaper[calendar] @ git+https://github.com/markhhm/ulani-epaper#subdirectory=python"
```

## Development

From the repository root (Windows shown; elsewhere use `python3 -m venv
.venv` and `.venv/bin/python`):

```powershell
git clone https://github.com/markhhm/ulani-epaper.git
cd ulani-epaper
py -m venv .venv
.venv\Scripts\python -m pip install -e "python[dev,calendar]"
.venv\Scripts\python -m pytest python\tests
```

Calling `.venv\Scripts\python` directly needs no venv activation and is not
affected by the PowerShell execution policy.

The tests cover the protocol, image conversion, the upload and push logic,
connection retries, the relay, the calendar pages (iCal parsing, feeds,
layouts, sync, schedule) and the desktop app. Bluetooth is replaced by
fakes, and fixtures make any test that reaches real Bluetooth or the network
fail; settings go to a temporary folder and the OS credential store is
replaced by a dict, so the suite is safe to run next to a paired device and
your own settings. The desktop app tests skip themselves when Tk has no
display.

Reference data in `shared/` is checked against the library. After a
deliberate change, regenerate it from the repo root (and look at every
image):

| Test | Reference | Regenerate with |
|---|---|---|
| `test_vectors.py` | `shared/vectors/ulani-vectors.json` | `python -m ulani_epaper.vectors shared/vectors/ulani-vectors.json` |
| `test_ical.py` | `shared/vectors/ical-vectors.json` (from `shared/vectors/ical/*.ics`) | `python -m ulani_epaper.ical shared/vectors/ical shared/vectors/ical-vectors.json` |
| `test_layouts.py` | `shared/layouts/agenda/golden/` (from `shared/layouts/agenda/*.json`) | `python -m ulani_epaper.layouts shared/layouts/agenda shared/layouts/agenda/golden` |

`python/scripts/subset_font.py` rebuilds the bundled font subsets (needs
fontTools).

## Library

### `push_images`: photos to pages in one call

```python
import asyncio
from ulani_epaper.push import push_images

results = asyncio.run(push_images(
    {1: "beach.jpg", 3: "cat.png"},     # or a list: item n goes to page n + 1
    fit="contain",                      # "cover" (default), "contain" or "stretch"
    progress=lambda e: print(e.slot, e.phase, e.sent, e.total),
))
print(results)                          # e.g. {1: UploadResult.OK, 3: UploadResult.UNCHANGED}
```

- `images` is a sequence of up to four sources (`None` leaves that page
  alone) or a mapping `{page: source}`; a source is a file path or a PIL
  image.
- Everything goes over one connection. The page on screen is uploaded last,
  so the panel refreshes only once (about 40 s, at the end).
- Each value in the result is `UploadResult.OK`, or `UploadResult.UNCHANGED`
  when the page already held exactly that image (nothing is sent).
- `progress` receives `PushEvent`s with `phase` `start`, `sending`, `done`,
  `unchanged` or `refreshing`, plus `slot`, `index`/`count` and
  `sent`/`total` bytes.
- Keyword arguments: `fit`, `dither=True`, `address=None` (first device
  found) and anything `client.connect` accepts, e.g. `attempts=4`,
  `retry_delay=5.0`, `flush_every=10`, `chunk_delay=0.0`.

### `prepare` and `push_frames`: convert first, upload later

```python
import asyncio
from ulani_epaper import image
from ulani_epaper.push import prepare, push_frames

frames = prepare(["a.jpg", "b.jpg"])          # {1: frame, 2: frame}, offline
image.preview(frames[1]).save("page1.png")    # how page 1 will look on the panel
asyncio.run(push_frames(frames))
```

A frame is 192 000 bytes: 800 × 480 pixels, 4 bits each, palette indices
0–6 (black, white, green, blue, red, yellow, orange). `image.encode(img,
fit_mode="contain", dither=True, strength=1.0)` converts a single PIL image
(`strength` below 1 spreads less of the dithering error: less grain, more
banding; `image.GRAIN` holds the levels Paperhue offers);
`image.render_text("Hello", colour="red")` draws text as large as fits
(encode it with `dither=False`).

### Lower level: `connect` and `Calendar`

```python
import asyncio
from ulani_epaper import image
from ulani_epaper.client import connect

async def main():
    with image.open_image("photo.jpg") as img:
        frame = image.encode(img, fit_mode="cover")
    async with connect() as cal:              # find, connect, unlock; retried 4 times
        print(await cal.battery(), await cal.current_slot())
        await cal.upload(frame, 2)            # one page
        await cal.show(2)                     # same as pressing the button

asyncio.run(main())
```

`Calendar` also has `push_pages(frames)`, `device_info()`, `model()` and
`firmware()`. [`examples/test_card.py`](examples/test_card.py) draws and
uploads a colour test card.

### Errors and large photos

- Every error the package raises on purpose is a `UlaniError`
  (`client.NoReply`, `client.DeviceBusy` while the panel is refreshing,
  `client.UploadFailed` when the device rejects the data). A failed push
  raises at the first failing page, with `.slot` (that page) and `.results`
  (pages already done). Bluetooth link errors can also surface as
  `bleak.exc.BleakError` or `OSError`.
- Pillow refuses images above about 179 megapixels, and some phones take
  200 MP photos. The library never changes Pillow's process-wide
  `Image.MAX_IMAGE_PIXELS`; the `ulani` command and Paperhue raise it to
  `image.MAX_PHOTO_PIXELS` (400 MP). Do the same in your own app if you need
  it. `image.open_image` decodes large JPEGs at reduced size, so memory use
  stays small.

## Command-line tool

| Command | What it does |
|---|---|
| `ulani scan [-t SEC]` | list devices in range (default 20 s; they advertise only now and then) |
| `ulani info` | model, firmware, serial, MAC, battery and the page on screen |
| `ulani show N` | switch the page on screen to N (1–4), like pressing the button |
| `ulani push IMAGE [IMAGE ...]` | 1–4 images to pages 1–4 in one connection, page on screen last; `--save-preview DIR` writes `page1.png` … |
| `ulani send IMAGE -s N` | one image to page N; `--save-preview PNG` |
| `ulani text "TEXT" -s N` | render text and upload it: Chinese works, `\n` breaks lines; `--colour`, `--background` (black, white, green, blue, red, yellow, orange), `--font FILE` |
| `ulani preview IMAGE -o OUT.png` | save how the panel will show an image, without a device |
| `ulani pages [1=month 2=agenda 3=todo 4=photo]` | show or set what each page shows |
| `ulani pages N --background FILE [--crop L T W H]` \| `ulani pages N --clear-background` | draw calendar page N on your own photo (the crop is fractions 0–1 of the photo, 5:3) or take it off |
| `ulani note add TEXT \| list \| remove N \| clear \| push` | the message board; `push` sends the saved notes to the board pages again (after a failed post or `--no-push`), a sync never redraws them |
| `ulani card list \| add IMAGE_OR_COLOUR TEXT... \| push N \| preload N... \| export N FILE \| import FILE` | cards: `push` shows one on a card page, `preload` fills the card pages with several without switching the display |
| `ulani feeds [add NAME \| edit \| remove \| test]` | list, add, change, remove or test the calendar sources; `add` asks for the address without showing it |
| `ulani sync [--dry-run]` | fetch the sources, draw the calendar pages and push them now |
| `ulani schedule install [--times 06:00 12:00 18:00] \| remove \| status` | sync every day at fixed times (Windows Task Scheduler, task "Paperhue Sync") |
| `ulani selftest` | check the installation without Bluetooth or network: fonts, page and card drawing, iCal, credential store |

Common options:

- `-a ADDRESS`, before or after the command: use this device (from
  `ulani scan`) instead of the first one found.
- `--fit contain|cover|stretch` (`send` and `preview` default to `contain`,
  `push` to `cover`) and `--no-dither` (nearest colour instead of dithering).
- `--dry-run` (`push`, `send`, `text`): convert only, do not connect.
- `--flush-every N` (default 10) and `--chunk-delay SEC`: upload pacing. If
  uploads fail with `02 01`, try `--chunk-delay 0.06`.

`python -m ulani_epaper` runs the same tool. Exit codes: 0 success, 1 error,
2 bad arguments, 130 interrupted.

Uploading the page on screen makes the panel refresh for about 40 s, during
which the device does not answer. Connections are retried (4 attempts, 5 s
apart); if they still fail, wait a minute. After an upload to a page that is
not on screen, `ulani show N` displays it.

## Building Paperhue.exe

```powershell
powershell -ExecutionPolicy Bypass -File python\scripts\build_windows.ps1
powershell -ExecutionPolicy Bypass -File python\scripts\build_windows.ps1 -Python C:\path\to\python.exe
```

- Without `-Python`, the `py` launcher picks the first installed Python of
  3.12, 3.13, 3.14, 3.11 and 3.10.
- The script works in its own venv, `python\.build-venv\` (git-ignored), and
  installs the package with the `calendar` extra and PyInstaller with the
  exact versions in `python\scripts\build-constraints.txt`, the set tested
  on a real device. Change those deliberately and test on hardware again.
- The result is a single file, `python\dist\Paperhue.exe`, with the fonts
  bundled. The script then runs `Paperhue.exe --selftest` (draws the three
  calendar pages, reads an iCal sample, finds the Windows credential store),
  starts the app once, waits for the Paperhue window and closes it again (no
  Bluetooth or network involved).
- `Paperhue.exe --sync` runs one calendar sync without a window; the daily
  schedule uses it.
- CI builds Paperhue.exe with this script for every push and pull request
  that changes `python/`. For a `v*` tag it attaches that build to the
  GitHub release, with `.github/release-notes/<tag>.md` as the release
  notes.
