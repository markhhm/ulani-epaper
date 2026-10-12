# Paperhue web (紙彩)

One TypeScript code base for Paperhue, which puts photos on ULANI e-paper
devices (ULANI 永恆曆):

- a PWA for the Bluefy browser on iPhone and for desktop / Android Chrome,
  talking to the device through Web Bluetooth;
- the Android app (app id `io.github.markhhm.paperhue`), the same web code
  packaged with Capacitor and a native BLE plugin.

Stack: Vite, TypeScript (strict), Preact, Vitest. Dependency versions are
pinned exactly in `package.json` and locked in `package-lock.json`; `.npmrc`
keeps new installs exact.

## Setup

Node.js 22.12 or later (development uses Node 24).

```sh
npm ci
```

## Commands

| Command | What it does |
|---|---|
| `npm run dev` | Dev server with hot reload. Open the printed URL; `/spike.html` is the diagnostics page. |
| `npm run build` | Type-check, then build both pages into `dist/`. |
| `npm run preview` | Serve `dist/` locally. |
| `npm test` | Run the unit tests once (Vitest). |
| `npm run typecheck` | Type-check `src/`, `test/` and the config files without emitting. |

Web Bluetooth only works in a secure context: `localhost` on the development
machine, otherwise https. To try the PWA on a phone, serve a build over https
(for example from GitHub Pages); `base: './'` makes the build work under any
sub-path and inside the Android WebView.

## Diagnostics page

`spike.html` (code in `src/spike/`) finds out, on a real device, whether a
browser can run Paperhue: open it in Bluefy on an iPhone, or in Chrome on
Android or a computer, and tap through the steps from top to bottom.

1. 檢查瀏覽器 (check the browser, runs on load): `navigator.bluetooth`,
   `getAvailability()`, secure context, the write methods on
   `BluetoothRemoteGATTCharacteristic.prototype`, the user agent. Some
   browsers (Bluefy) have no such global class although their characteristics
   have the methods: the check then says INFO, and connecting (step 3) reports
   the methods of the device's real image characteristic instead.
2. 行事曆下載測試 (calendar download test, no Bluetooth): on tap, fetches
   the public Taiwan holidays iCal feed from Google Calendar with `fetch()`
   (no credentials, no proxy; `src/spike/calendarFeed.ts`) and shows PASS
   (HTTP status, size, starts with `BEGIN:VCALENDAR`, events) or BLOCKED
   (the browser's CORS or network error, which means calendar pages cannot
   be synced in that browser). A readable answer that is not calendar data
   fails too.
3. 連線 (connect): device chooser, connect, notifications, unlock; shows the
   device name, model and firmware, then reads the status. Before a phone
   connects for the first time, put the device in pairing mode (hold its
   button about 5 s until the LED blinks green) and accept the pairing
   prompt. Each attempt gets about 15 s; attempts that get no answer go on
   for up to about 90 s. When the device drops an attempt before
   notifications are on (what it does to a phone it does not know while it
   is not in pairing mode), the page shows the pairing-mode hint at once.
   When the pairing no longer works, the page says to forget the device in
   the Bluetooth settings and pair again the same way.
4. 讀取狀態 (read status): battery and the page on screen. These queries
   (and the device information) are asked once more when the first try gets
   no reply.
5. 切換頁面 (switch page): pages 1-4. The panel then redraws for about 40 s
   and the device usually drops the link 14-25 s in. The page says so, with a
   countdown, instead of reporting an error, and reconnects by itself once the
   refresh should be over (45 s after it started). A test card sent meanwhile
   rides out the drop and goes on after the reconnect; a status read the drop
   cuts off shows WARN, not FAIL. Stop works at once, also while an upload
   waits for the reconnect.
6. 傳送測試圖 (send a test card): page (default: one that is not on screen),
   write mode (auto / without response / with response), chunk size (180 /
   120 / 20 bytes) and flush interval. Draws a card (`testCard.ts`: seven
   colour bars, the page number, "Paperhue test", the time), uploads it with
   progress and shows total time, data time, throughput and the result (OK /
   unchanged / error). Uploading to the page on screen makes the panel refresh
   for about 40 s, during which the device answers nothing; the page handles
   it as in step 5. The screen is
   kept on during the upload (`src/keepAwake.ts`: the Screen Wake Lock API in
   browsers, a native flag in the Android app); where neither exists, the page
   asks the user to keep it on.
7. 中斷連線 (disconnect).

A PASS / FAIL / WARN / INFO checklist sums up the steps. 複製紀錄 (copy log) copies the
checklist, the results (the calendar download included) and the timestamped
log of every command and reply, to paste into a message. Errors show in plain
words with the technical message (English) underneath.

The page and the app shell are in Traditional Chinese or English
(`src/i18n.ts`, every string in both). The language comes from
`navigator.languages` (zh-* is Chinese, anything else English) until the
button in the top bar, labelled with the other language ("English" / "中文"),
switches it; that switches every text at once and the choice is kept in
`localStorage` (`paperhue.locale`; the page works without it). Technical
details, the log and the device chooser's internals stay in English. The
hardware is called 裝置 / device; "calendar" (行事曆) only ever means
calendar data such as the iCal feed (`test/i18n.test.ts` checks both).

The page loads nothing from other sites: `test/spike/selfContained.test.ts`
checks its HTML, scripts, styles and strings, and allows exactly one outside
address, the holidays feed, which only the calendar download button fetches.

`src/spike/diagnostics.ts` runs the steps without any DOM, so the tests drive
it with the fake device and a stand-in `fetch`; `view.ts` builds the page. It
gets its transport from `createTransport()` and sets what the session API does
not cover on the transport when it has the property: `writeMode`,
`writeLength` (the chunk size; Web Bluetooth only, the Android plugin uses the
negotiated MTU) and `logger`.

## GitHub Pages

`.github/workflows/web.yml` runs on pushes to `main` that touch `web/` or
`shared/`, and by hand: Node 24, `npm ci`, `npm test` and `npm run build` in
`web/`, then it deploys `web/dist` to GitHub Pages. Pull requests that touch
those paths run the same tests and build, without deploying. Set the
repository's Pages source to "GitHub Actions" once (Settings, Pages). The
diagnostics page is then at `https://<owner>.github.io/<repository>/spike.html`.

## Android app

`android/` is the Capacitor project (`capacitor.config.ts`: app id
`io.github.markhhm.paperhue`, name Paperhue, web assets from `dist/`). For now
the app opens on the diagnostics page (`server.appStartPath`), which links to
`index.html` and back. Inside the app, `src/ble/select.ts` picks
`src/ble/capacitorBle.ts` (the `@capacitor-community/bluetooth-le` plugin)
instead of Web Bluetooth. The app has one plugin of its own,
`ScreenAwakePlugin.java` (registered in `MainActivity.java`), which keeps
the screen on during uploads.

Needs JDK 21 and an Android SDK with `platform-tools`, `platforms;android-36`
and `build-tools;35.0.0` (`JAVA_HOME` and `ANDROID_HOME` set). Then:

```sh
npm run build
npx cap sync android
cd android
sh ./gradlew assembleDebug     # Windows: gradlew.bat assembleDebug
```

Run the first two commands before every local build: the package contains
whatever `npx cap sync` last copied into `android/`, so skipping them ships
an old web build.

The installable package is
`android/app/build/outputs/apk/debug/app-debug.apk`. The Bluetooth permissions
are in `android/app/src/main/AndroidManifest.xml`: Nearby devices
(`BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_CONNECT`) on Android 12
and later, the legacy Bluetooth and location permissions up to Android 11.
`python scripts/gen_android_icons.py` (needs Pillow) redraws only the splash
images (`drawable*/splash.png`) from the 1024 px master icon,
`../shared/brand/paperhue-1024.png`. The launcher icons (`mipmap-*/`,
including the adaptive icon's layers) are not generated: they are copied from
the Paperhue icon set. CI builds the debug package in
`.github/workflows/android.yml`.

## Layout

```
index.html, spike.html   the app shell and the diagnostics page (titles, description,
                         favicon and touch icon links)
public/                  web app manifest, favicons and icons, copied as-is
src/core/                pure code, no DOM or Bluetooth: protocol, palette,
                         frames, fitting, dithering
src/ble/                 Transport (the BLE link interface) and its backends
                         (webBluetooth.ts, capacitorBle.ts); select.ts picks
                         the backend for the platform
android/                 the Capacitor Android project
src/session/             the device session (unlock, status, uploads, pushes)
src/app/                 the app UI (Preact)
src/spike/               the diagnostics page
src/i18n.ts              UI strings in zh-TW and English, the language button's state
src/keepAwake.ts         keeps the screen on during uploads
test/                    Vitest tests; fakeTransport.ts stands in for Bluetooth
scripts/                 generators for the dither and fit test vectors and
                         the Android splash images
../shared/vectors/       test vectors shared with other implementations
../shared/brand/         the 1024 px master icon (for the splash images)
```

Tests never use Bluetooth, real hardware or the network: anything that needs a
link gets `FakeTransport`. `test/vectors.ts` loads every JSON file in
`../shared/vectors/` and has helpers to rebuild the inputs the vectors refer to.

`shared/vectors/dither-vectors.json` pins the exact palette indices of the
Stucki ditherer (`src/core/dither.ts`), including the output without
dithering (the exact nearest colour). From the repository root,
`python web/scripts/gen_dither_vectors.py` rebuilds it with plain Python 3 (no
packages): the script carries its own implementation of the procedure
documented in `dither.ts`.

`fit-vectors.json` pins the fitting geometry. It was recorded from the Python
package in `python/src/ulani_epaper` (needs Pillow): from the repository
root, run `PYTHONPATH=python/src python web/scripts/gen_fit_vectors.py`.

The panel is 800 x 480 with seven colours; a frame is 192 000 bytes (two
pixels per byte, first pixel in the high nibble). `src/core/protocol.ts`
documents the messages.
