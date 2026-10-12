# ULANI e-paper device BLE protocol

How Paperhue talks to the ULANI 7-colour e-paper device (ULANI 永恆曆)
over Bluetooth LE. Tested on a real unit (model `P7320E-B`, firmware
`v1.0.09`); anything not tested says so.

Byte values are hex. Multi-byte integers are big-endian.

Implementations: Python in [`python/src/ulani_epaper/`](../python/src/ulani_epaper/)
(`protocol.py` byte layouts and checksums, `client.py` session and uploads,
`image.py` frame encoding) and Swift in [`apple/UlaniKit/`](../apple/UlaniKit/).
Both are checked against the shared test vectors in
[`vectors/ulani-vectors.json`](vectors/ulani-vectors.json).

## Hardware summary

| | |
|---|---|
| Panel | 800 x 480, E Ink Gallery Palette, 7 colours |
| Radio | Bluetooth LE only. The USB-C port is charge-only (never enumerates) |
| Advertised name | `ULANI Calendar` + last 6 hex digits of the MAC |
| Advertised service | 16-bit `A200` |
| Button | cycles through pages ("slots") 1-4; long press (5 s) = pairing mode |

The device renders nothing itself: every page is a full-screen bitmap
uploaded over BLE, which the device only stores and displays.

## GATT

| UUID | Properties | Use |
|---|---|---|
| `00002a24-...` (Device Information) | read | model number, e.g. `P7320E-B` |
| `00002a26-...` (Device Information) | read | firmware revision, e.g. `v1.0.09` |
| `1234a200-7cbc-11e9-8f9e-2a86e4085a59` | service | device service |
| `1234a201-7cbc-11e9-8f9e-2a86e4085a59` | write, read, notify | **command**: requests in, replies out as notifications |
| `1234a202-7cbc-11e9-8f9e-2a86e4085a59` | write without response, read, notify | **image**: frame data in, final result out |

Both characteristics of this service require an **encrypted (bonded) link**;
unbonded access fails with *Insufficient Authentication*. Pair once in the
OS Bluetooth settings while the device is in pairing mode (hold the button
~5 s until the LED blinks green).

Pairing at the OS level is all that is needed: a Windows PC bonded this
way has full control. Any other paired phone or computer can also upload
pages and overwrite yours. Whether the firmware keeps more than one bond at
a time has not been tested.

Right after connecting, the device notifies `05 00` (device ready) on the
command characteristic.

## Commands (write to command char, reply is notified there)

| Request | Reply | Meaning |
|---|---|---|
| `04 4E 42` | `04 00` | **unlock**: the payload is always the ASCII bytes `NB`. No account, key or per-device secret is involved |
| `06 00` | `06 LL` | battery: `LL` = 0 (lowest) to 5 (full), `06` = charging |
| `0A 00` | `0A` + MAC(6) + ASCII serial | device info |
| `0C 00` | `0C SS` + CRC32(4) | page currently shown (`SS`) and CRC32 of its image |
| `0B SS` | `0B 00` | **show page `SS`** (1-4), same as pressing the button |
| `09 03` | `09 00` | goodbye; the device goes back to idle |
| `01 ...` | see below | image upload header |

Paperhue sends only the commands in this table; its relay
(`python -m ulani_epaper.relay`) refuses every other opcode.

## Image upload

### Frame format

* 800 x 480 pixels, row-major, top-left first, no rotation.
* 4 bits per pixel, 2 pixels per byte, **first pixel in the high nibble**.
* 192 000 bytes per frame.
* Colour index: `0` black, `1` white, `2` green, `3` blue, `4` red,
  `5` yellow, `6` orange (Paperhue's palette uses RGB 255,125,0 for orange).

Any dithering works. Paperhue for Windows uses Stucki error diffusion; the
Swift encoder uses Floyd-Steinberg.

### Sequence

1. (command) `04 4E 42` -> `04 00`
2. (command) 13-byte header -> reply:

   ```
   01 | length (u32) | slot (u8) | mode (u8) | CRC32 (u32) | CRC16 (u16)
   ```

   * `slot`: page 1-4. Firmware v1.0.09 does not answer headers for other
     slots (tried with 16).
   * `mode`: Paperhue always sends `01` (tested, works); other values have
     not been tested.
   * `CRC32`: standard (zlib / IEEE 802.3) over the frame.
   * `CRC16`: CRC-16/XMODEM (poly `1021`, init `0000`) over the frame.

   | Reply | Meaning |
   |---|---|
   | `01 00` | go ahead |
   | `01 01` | busy: Paperhue waits and sends the header again |
   | `01 02` | slot already holds an image with this CRC; nothing to do |

3. (image char) stream the frame with write-without-response, at most
   `MTU - 3` and at most 230 bytes per packet.
   **Start within ~4 s** of `01 00`, or the device gives up with `02 01`.
4. (image char, notification) `02 00` = stored OK, `02 01` = failed
   (CRC mismatch or timeout).

### Uploading several pages

Measured by uploading slots 1, 2, 3, 4 back to back in **one connection**
while slot 2 was on screen:

* The link stays up after `02 00`; there is no need to reconnect.
* Uploading a page that is **not** on screen does not refresh the panel; the
  next header is answered immediately.
* Uploading the page that **is** on screen refreshes the panel for ~40 s.
  During the refresh the device **does not answer at all** (the next header
  got no reply for 43 s, then `01 00`).
* A new connection attempted during the refresh failed while enabling
  notifications (WinRT "operation cancelled") and worked ~40 s later.
  In a later run (2026-10-12, Swift client through the relay) the device
  was not found by a 40 s scan right after the shown page was replaced (it
  did not advertise during the refresh); the retry 5 s later connected and
  the push completed. Either way: retry the whole setup.

So to fill all four pages quickly: read the shown page with `0C 00`,
upload the other three first and the shown page last; the panel refreshes
once, at the end. Verified with `ulani push` (four photos, page 3 on
screen): uploaded in the order 1, 2, 4, 3 in 105 s. The Swift client
(`ulani-swift` through the relay on the same PC, 2026-10-12) did the same
in 122 s (connect 29 s, push 93 s, 21-29 s per page).

### Checking what a page holds (header-only probe)

Sending only the 13-byte header of frame X for page N answers `01 02` if
page N already holds exactly X (same CRC32/CRC16): nothing is written and
the panel does not refresh. Verified on hardware for all four pages after a
push, so it can confirm a push without changing what is on screen.
Verified again from the Swift client (all four pages `01 02`, 1 s in total).

Otherwise the device answers `01 00` and waits for data; with none it is
expected to give up with `02 01` after ~4 s (seen once, for a header sent
without data). **Not yet tested:** whether the stored page, especially the
one on screen, survives that. Only probe pages you expect to match.

### Flow control (important on Windows)

On Windows, write-without-response returns as soon as the packet is
*queued*: all 835 packets of a frame "completed" in 0.6 s and the device
answered `02 01` about 42 s later, as did a run with 30 ms between packets.
The most likely explanation is that the OS write queue overflows and drops
packets. In those first single-page runs the link sustained about 4 KB/s at
Windows' default 60 ms connection interval; later four-page pushes went
faster (~25-30 s per frame, ~6-7 KB/s), so the speed depends on the
connection.

Two fixes, each verified on Windows 11:

* **Read barrier** (used by default): every 10 packets, read the firmware
  revision characteristic. ATT requests are serialised, so the read
  completes only after the queued writes have gone out. `02 00` in every
  run: 39-50 s per frame in the first runs, 23-30 s per frame in later
  four-page pushes.
* Fixed delay of ~60 ms per packet: `02 00`, ~52 s per frame.

Requesting Windows' `ThroughputOptimized` connection parameters lowered the
interval to 15 ms but the device dropped the link mid-transfer, so this
is not used.

## Other observations

* Advertising is sparse (power saving). In testing an 8 s scan missed the
  device and a 20 s search once missed it too; retrying worked. Scan for
  20 s or more and retry.
* MTU is negotiated by the OS shortly after connecting (23 -> 247 on
  Windows, ~1.5 s), so wait for it before choosing the packet size.
* Once, right after an upload to slot 2, `0C 00` reported slot 3 with CRC
  `FFFFFFFF` (cause unknown; not seen again). `0B 02` switched back.
