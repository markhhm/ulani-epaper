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

## The app

`index.html` (code in `src/app/`) is the phone app: cards, photos, the page plan and backups, in
Traditional Chinese or English (the button in the top bar, `src/i18n.ts`). Open it in Bluefy on an
iPhone, in Chrome on Android or a computer, or in the Android app. The device status sits at the top
(connect, battery, what is being sent, the countdown while the panel redraws); the four sections are
tabs under it.

- **我的牌卡 / My cards**: the saved cards as 5:3 thumbnails (drawn in the panel's seven colours, kept
  so they appear at once). One tap shows a card on the device with the rule of the Python app
  (`python/src/ulani_epaper/sync.py`, `core/cardPush.ts`): it goes to the card page it is already on,
  else the card page on screen, else the lowest card page; a card that is already on a page is only
  switched to (the device skips an image it holds). With no card page, the app offers in one tap to
  make the photo page (or page 4) a card page, before it connects. "Preload" puts chosen cards on the
  card pages in one push without switching; each card shows the page it sits on. A `.paperhue-card`
  file imports a card (made by any app); the editor saves one.
- **The card editor** (`CardEditor.tsx`): a background (one of the 7 colours, or a photo from the file
  chooser or the camera) and up to 8 texts. Drag a text to move it, pinch (or the wheel, or the
  sliders) to resize, choose the colour, an outline and its colour, alignment, delete; a tap on a
  text edits it. The preview is the drawing the device gets: the photo cut and dithered (Stucki, with the
  grain setting), the text drawn crisp in pure panel colours (`core/cardRender.ts`).
- **照片 / Photos**: choose or take a photo, pick the part that fills the screen (crop editor: drag,
  pinch, zoom slider, reset), Fill or Fit, grain, and send it to a photo page.
- **頁面 / Pages**: which kind each of the four pages shows (the plan lives only in this app), and the
  grain. The calendar pages (below) are previewed here and sent with one tap; notes and board pages
  are not drawn by this app yet.
- **備份 / Backup**: export and import everything as one file (below).

Every photo goes through one load step (`app/photoLoad.ts`, `core/photo.ts`): over 50 megapixels is
refused from the file header (a format whose header is not read is refused after decoding), the rest is
oriented and shrunk to the 4K cap with the exact sizes of `shared/vectors/photo-cap-vectors.json`.
Crops (`core/crop.ts`, `shared/vectors/crop-vectors.json`) are fractions of that full capped photo and
the screen picture is cut from it, never from a preview. A card's photo is stored as a JPEG (quality
92) at that size.

Card text is drawn with the system's bold Traditional Chinese font (canvas); the layout (wrapping,
cutting with "…", line pitch, outline) is the Python one in `core/cardLayout.ts` and the tests compare
the strings it draws with the goldens in `shared/layouts/card/golden/*.txt`, using the font's widths
recorded from Python (`test/fixtures/card-metrics.json`, `scripts/gen_card_metrics.py`). Pixels differ
slightly between apps because the fonts do.

### Calendar pages

The five calendar pages (本日＋月曆, 本日行程＋一週行程, 待辦, 日, 月曆) are drawn by
`core/calendarPages.ts`, a port of `python/src/ulani_epaper/layouts.py` that follows
`shared/LAYOUTS.md`, with and without a background photo (the photo already cut and dithered, all text
white with a black outline). `core/agenda.ts` is the data model of `agenda.py` (events with a colour,
tasks). It reads the payload `{"v": 1, "events": [...], "reminders": [...]}` that the iPhone Shortcut
sends: times become the wall clock of the phone's time zone, all-day events are dates with an
exclusive end.

The pages use the bundled Noto Sans CJK TC subset fonts (`public/fonts`, the files of the Python app;
a test checks that they are identical). Widths and the characters the font has come from the font file
itself (`core/otf.ts`: whole-pixel advances, exactly as Python's Pillow measures them), so text is cut
and wrapped in the same places as in Python whatever fonts the system has. The canvas
(`app/calendarFont.ts`, the fonts loaded with `FontFace`) only draws the glyphs, and every pixel then
becomes ink or not, in the panel's seven colours with no anti-aliasing.
`test/calendarPages.test.ts` compares the strings drawn for the shared fixtures with
`shared/layouts/agenda/golden/*.txt`. The two font files are 11 MB together and are loaded the first
time the Pages section is opened.

**The default calendar.** With no calendar of the user's own, the pages show Taiwan's public holidays.
Google's feed cannot be read from another site in a browser, so `.github/workflows/web.yml` downloads it
at every build and once a day (`schedule`), converts it with the Python reference (`ical.parse`, in
`scripts/tw_holidays.py`) and writes `dist/data/tw-holidays.json`; the app reads that file from its own
site (`core/defaultCalendar.ts`). It holds public data only. To try the app with `npm run dev`, make
the file once, from the repository root (git ignores that folder):
`PYTHONPATH=python/src python web/scripts/tw_holidays.py web/public/data/tw-holidays.json`.

### iPhone sync (the Shortcut)

The signed Shortcut "Paperhue 同步" (`public/shortcuts/Paperhue-Sync.shortcut`, spec in `shared/SHORTCUT.md`)
reads the phone's calendars and reminders and opens `<site>/?sync=1#d=<base64 of the payload JSON>` in
Bluefy. `main.tsx` reads it with `core/shortcut.ts` (`readSyncRequest`: the `?sync=1` flag, then the
fragment, which no server sees), drops it from the address at once with `history.replaceState`, and
hands it to `AppModel.syncFromShortcut`. The calendar stays in the model's memory (it is never saved,
not even as a fingerprint) and every calendar page then draws from it instead of the default calendar.
The model keeps the screen on (`keepAwake.ts`: the Wake Lock API plus Bluefy's
`navigator.bluetooth.setScreenDimEnabled(false)`), draws the pages whose kind is a calendar kind, finds the
device again without a tap (`app/device.ts` `reconnectDevice`: `navigator.bluetooth.getDevices()`, then
`gatt.connect()` through a `WebBluetoothTransport` given that device; about 60 s of attempts, then
`ConnectFailed`, which the page shows as "not found" without an error box), and sends all of them in one
push. The device itself answers "same image" for a page it already holds, so only changed pages are
uploaded; the result is shown as updated / already up to date. No card, photo or notes page is touched
and the page on screen is not switched. The Pages section on an iPhone has the **Sync now** link
(`shortcuts://run-shortcut?name=Paperhue%20%E5%90%8C%E6%AD%A5`) and a link to the Shortcut file.
Tests: `test/shortcut.test.ts`, `test/modelSync.test.ts`, `test/session/reconnect.test.ts`.

### Local storage and backup

Cards, their photos, the settings (page plan, grain, the fingerprint of the frame last sent to each
card page) and the frames drawn last are kept in the browser's IndexedDB (`app/idbStore.ts`; the
`Store` interface is in `core/library.ts`, with a memory store for tests and for browsers that refuse
storage, which the app says). Nothing leaves the device. **iOS may clear a website's data when it has
not been opened for a while**, so the app treats the data as a cache: it asks the browser to keep it
(`navigator.storage.persist()`), reminds you that no backup exists, and the Backup section says so.
The backup is a zip (`paperhue-backup-YYYY-MM-DD.zip`): `settings.json`, `cards.json` (the format of
`shared/CARDS.md`) and `backgrounds/<id>.jpg`. Importing replaces everything, after checking the whole
file (every card, every photo through the photo rules); a file that fails changes nothing.

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
`shared/`, by hand and every day: Node 24, `npm ci`, `npm test` and `npm run build` in
`web/`, then it adds the default calendar (above) and deploys `web/dist` to GitHub Pages. Pull requests that touch
those paths run the same tests and build, without deploying. Set the
repository's Pages source to "GitHub Actions" once (Settings, Pages). The
diagnostics page is then at `https://<owner>.github.io/<repository>/spike.html`.

## Android app

`android/` is the Capacitor project (`capacitor.config.ts`: app id
`io.github.markhhm.paperhue`, name Paperhue, web assets from `dist/`). The app
opens on `index.html`. Inside the app, `src/ble/select.ts` picks
`src/ble/capacitorBle.ts` (the `@capacitor-community/bluetooth-le` plugin)
instead of Web Bluetooth. The app's own Java code (registered in
`MainActivity.java`):

- `ScreenAwakePlugin.java` keeps the screen on during uploads.
- `PaperhuePlugin.java` (`src/app/android.ts`): the calendar permission
  (`READ_CALENDAR`, asked the first time the Pages section opens), the phone's
  calendars (`PhoneCalendar.java`, `CalendarContract.Instances` for the days the
  pages show) and the scheduled sync's times and log. iCal addresses are
  fetched natively (CapacitorHttp, no CORS) and parsed in TypeScript
  (`core/ical.ts`, `core/sources.ts`, checked against
  `shared/vectors/ical-vectors.json`); the addresses stay in the WebView's
  storage on the phone.
- The scheduled sync (off until the user adds times): `SyncScheduler.java`
  sets one exact alarm for the next time; `SyncAlarmReceiver.java` starts
  `SyncService.java`, a foreground service (connected device) that loads
  `background.html` (`src/background/`) in a WebView without a screen at the
  app's own address, so the page reads the app's storage and reuses the model,
  drawing and device session. `SyncBridge.java` gives that page Bluetooth GATT
  (to the device the app connected to last), the calendar query and HTTP
  (`src/background/native.ts`). When the device is not found the run is tried
  again every 15 minutes for 2 hours after the chosen time, then skipped; the
  last 20 runs are logged and shown in the app. Adding the first time asks
  once to leave the app out of battery optimisation. `RescheduleReceiver.java`
  plans the alarm again after a restart, an update or a clock change. The
  rules are tested in `app/src/test` (`gradlew testDebugUnitTest`).

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
the Paperhue icon set. CI builds the debug package and runs the Java unit tests
in `.github/workflows/android.yml`. On `v*` tags it also builds the release
package with the version of the tag (`v0.3.1`: version name 0.3.1, version code
301), signed with the release key from the repository secrets
(`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD`; `app/build.gradle` reads them through
`ANDROID_KEYSTORE_FILE` and the other variables), and attaches it to the release
as `Paperhue-Android.apk`. The key and its passwords are never in the
repository; the owner keeps the only other copy offline. Every release must be
signed with that same key, or Android will not install it over the app.

## Layout

```
index.html, spike.html   the app and the diagnostics page (titles, description,
                         favicon and touch icon links)
public/                  web app manifest, favicons and icons, copied as-is
src/core/                pure code, no DOM or Bluetooth: protocol, palette,
                         frames, fitting, dithering, photo size rules and crops,
                         cards (format, layout, drawing, editing, pushing),
                         zip, backup and card files (library.ts), settings
src/ble/                 Transport (the BLE link interface) and its backends
                         (webBluetooth.ts, capacitorBle.ts); select.ts picks
                         the backend for the platform
android/                 the Capacitor Android project
src/session/             the device session (unlock, status, uploads, pushes)
src/app/                 the app: the model (model.ts), browser parts (photo
                         loading, canvas text, IndexedDB, the device link) and
                         the Preact views in ui/
src/background/          the Android app's scheduled sync page (background.html)
src/spike/               the diagnostics page
src/i18n.ts              UI strings in zh-TW and English, the language button's state
src/keepAwake.ts         keeps the screen on during uploads
test/                    Vitest tests; fakeTransport.ts stands in for Bluetooth
scripts/                 generators for the dither and fit test vectors, the
                         card font metrics and the Android splash images
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
