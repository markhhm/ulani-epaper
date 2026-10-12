<p align="center"><img src="shared/brand/paperhue-1024.png" width="96" alt="Paperhue app icon"></p>

# Paperhue — free Windows app for the ULANI e-paper calendar (ULANI 永恆曆)

English | [繁體中文](README.zh-TW.md)

Paperhue is a free, open-source Windows app that puts your own photos on a
**ULANI 7-colour e-paper device**. Pick up to four photos, see how each
one will look in the panel's seven colours, and send them to the device over
Bluetooth. No account, no sign-in, no cloud.

![Paperhue on Windows after sending four photos to a ULANI e-paper device](docs/img/windows-app.png)

## What it does

The device stores four pages, and its button cycles through them.
Paperhue fills any of those pages with a photo you choose: it fits the photo
to the 800 × 480 screen, converts it to the panel's seven colours and sends
it over Bluetooth LE. The preview in Paperhue is drawn with only those seven
colours, so you can judge the result before you send it; on the paper itself
the colours look softer than on a monitor.

## Download

**[Download Paperhue.exe](https://github.com/markhhm/ulani-epaper/releases/latest/download/Paperhue.exe)**
(latest version)

- Windows 10 or 11, with Bluetooth LE (built into most laptops; a desktop PC
  may need a Bluetooth 4.0 or newer USB adapter).
- One file, nothing to install: save it anywhere and double-click it.
- Paperhue's screens are in Traditional Chinese. This guide gives the English
  meaning of every label you need.

## First-time setup

### 1. Let Windows open Paperhue

Your browser may first warn that Paperhue.exe is not commonly downloaded;
choose **Keep** (in Edge, open the **…** menu next to the download).

Paperhue.exe is not code-signed, so the first time you open it Windows may
say **"Windows protected your PC"**. Click **More info**, then **Run anyway**.

### 2. Pair the device with the PC (once)

The device only talks to computers it is paired with.

1. Hold the device's button for about 5 seconds, until the light blinks
   green (pairing mode).
2. On the PC, open **Settings → Bluetooth & devices → Add device →
   Bluetooth** (Windows 10: **Settings → Devices → Add Bluetooth or other
   device → Bluetooth**) and choose the device whose name starts with
   **ULANI Calendar**.
   If the device is not in the list on Windows 11, open **Settings →
   Bluetooth & devices → Devices**, set **Bluetooth devices discovery** to
   **Advanced**, put the device back in pairing mode and try again.
3. Open Paperhue and click **讀取狀態** (Read status). When the top line,
   裝置狀態 (device status), shows the battery level and the page on screen
   (for example 電量 4/5，目前顯示第 1 頁: battery 4 of 5, page 1 on screen;
   充電中 means charging), you are ready.

Another phone or computer that is also set up with the device can
overwrite your pages too; if you no longer use the device there, remove it
from that phone or computer.

## Putting photos on the device

1. For each page (**第 1 頁** to **第 4 頁**, page 1 to 4), click
   **選擇照片…** (Choose photo…) or the preview area, and pick a photo.
   JPG, PNG, BMP, GIF, WebP and TIFF work; convert HEIC photos to JPG first.
   Pages you leave empty stay as they are on the device. **清除** (Clear)
   removes the photo from that page in Paperhue; it does not erase anything
   on the device.
2. Choose the options above the pages (they apply to all four):
   - **填滿畫面（裁切多餘部分）** (Fill the screen, crop the rest): the photo
     fills the 5:3 screen. This is the default.
   - **完整顯示（留白邊）** (Show the whole photo, with white borders).
   - **抖色（照片建議開啟）** (Dithering, recommended for photos), on by
     default, mixes the seven colours into finer shades. Turn it off for
     drawings with flat colours.

   After a few seconds the previews show each photo in the panel's seven
   colours, captioned 預覽為裝置實際顯示的 7 色效果 (preview of what the
   device will show; 產生預覽中… means the preview is still being made).
   **推送到裝置** becomes available once every preview is ready.
3. Click **推送到裝置** (Push to device). Each page shows its own progress:
   等待中 (waiting) · 準備傳送（1/4） (getting ready, 1 of 4) · 傳送中 37%
   (sending) · 已是這張照片，略過 (already on the device, skipped) · 完成
   (done; 畫面約需 40 秒刷新 means the screen needs about 40 seconds to
   redraw) · 未完成 (not finished). At the end the bottom line shows, for
   example, 完成：3 頁已更新，1 頁原本就相同 (Done: 3 pages updated, 1 was
   already the same).

Paperhue sends the page that is on the device's screen last, so the panel
refreshes only once, at the end. Sending usually takes 25–30 seconds per page
(up to about 50 seconds on a slow Bluetooth link), so four pages take about
2 minutes. A page that already holds the same photo is skipped. Keep Paperhue
open until the bottom line says **完成** (Done). The device then needs about
40 seconds more to redraw its screen. The other pages are stored on the
device; press its button to see them.

If you close Paperhue while it is sending, it asks 確定要關閉嗎？ (Close
anyway?). Closing stops the push; just push again later.

**Shortcut:** drag up to four photos onto the **Paperhue.exe** file icon
(not onto the open window). Paperhue opens with them on pages 1–4. Windows
decides the order, so check each page before you push.

## Troubleshooting

When something goes wrong, Paperhue shows a pop-up titled 推送失敗 (Push
failed) or 讀取狀態失敗 (Read status failed). The first line explains the
problem in Chinese; the technical details under it are in English (a rare
unexpected error shows only the English text). Look up the first words here.
A photo that Paperhue cannot open shows 無法讀取 … under its page instead.

| Message | What to do |
|---|---|
| 裝置尚未與這台電腦配對 (not paired with this PC) | Pair the device as described above. |
| 找不到裝置或連不上 (device not found or cannot connect) | Bring the device near the PC, check that the PC's Bluetooth is on and that the device is paired with this PC, and make sure no other phone or computer is connected to it right now. Then push again. |
| 裝置沒有回應 (device not responding) | It is probably still refreshing its screen (about 40 seconds). Wait a minute and push again. |
| 裝置回報收到的資料有誤 (device received damaged data) | Push again. |
| 藍牙連線中斷 (Bluetooth connection lost) | Move the PC closer to the device and push again. |
| 無法讀取 … (cannot read a photo) | The file is damaged, too large, or in a format Paperhue cannot open (convert HEIC to JPG). |

More tips:

- The device sends a Bluetooth signal only now and then to save battery.
  Paperhue keeps trying for about two minutes before it gives up, so
  連線中… (Connecting…) or 連線並推送中… (Connecting and pushing…) can stay
  on screen for a while. If it gives up (a pop-up appears; after 讀取狀態 the
  top line says 裝置狀態：連不上, cannot connect), try again.
- If a push stops half-way, push again: pages that already hold their photo
  are skipped.
- If the device shows a different page after a push, press its button to
  go to the page you want.
- If the PC cannot connect any more after the device was paired with
  another phone or computer, remove the device in Windows' Bluetooth settings
  and pair it again.

Still stuck? Open an issue on
[GitHub](https://github.com/markhhm/ulani-epaper/issues) and include the
message Paperhue showed.

## Privacy

Paperhue needs no account and uses no cloud service. It does not connect to
the internet: your photos never leave your computer, except over the
Bluetooth link to your own device.

## For developers

Paperhue is built on a small Python library, `ulani-epaper`, which you can
use in your own scripts (Python 3.10–3.14):

```
pip install "ulani-epaper @ git+https://github.com/markhhm/ulani-epaper#subdirectory=python"
```

```python
import asyncio
from ulani_epaper.push import push_images

# photo n goes to page n; None leaves that page alone
asyncio.run(push_images(["a.jpg", "b.jpg", None, "d.jpg"]))
```

It also installs the `ulani` command-line tool (`ulani push`, `ulani send`,
`ulani text`, `ulani info`, …). [python/README.md](python/README.md) covers
the API, the command-line tool, tests and building Paperhue.exe;
[shared/PROTOCOL.md](shared/PROTOCOL.md) describes the Bluetooth protocol.

| Folder | Contents |
|---|---|
| [`python/`](python/) | the `ulani-epaper` library, the `ulani` command-line tool and the Paperhue Windows app |
| [`apple/`](apple/) | a Swift version of the library (in development, not released) |
| [`shared/`](shared/) | protocol notes and test vectors shared by both |
| [`docs/`](docs/) | images for the READMEs |

## License

MIT, see [LICENSE](LICENSE).

ULANI is a trademark of its respective owner. Paperhue is an independent
open-source project and is not affiliated with, endorsed by or sponsored by
ULANI.
