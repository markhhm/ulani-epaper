# Paperhue for macOS: developer notes

The Swift side of Paperhue (紙彩): a Swift package with the protocol, frame
encoder and push logic, the SwiftUI interface, a command-line tool for testing,
and the Xcode project that turns the interface into the macOS app. The
interface is in Traditional Chinese (zh-TW) or English (see
[Languages](#languages)) and behaves like the Windows app
(`python/src/ulani_epaper/gui.py`): pick up to four photos and put them on
pages 1-4 of a ULANI e-paper device.

## What is here

| Path | What |
|---|---|
| `UlaniKit/` | Swift package (`swift-tools-version` 6.0) |
| `UlaniKit/Sources/UlaniKit/` | Library, no UI: messages and CRCs (`Protocol/`), frame encoder (`Image/`), session, connector and push state machine (`Session/`), CoreBluetooth and relay links (`Transport/`) |
| `UlaniKit/Sources/PaperhueUI/` | SwiftUI interface, view model and all user-facing text in both languages (`Strings.swift`, `Language.swift`); nearly all of the app's code lives here |
| `UlaniKit/Sources/ulani-swift/` | macOS command-line tool (`info`, `push`, `probe`, `show`) for trying UlaniKit over Bluetooth or the relay |
| `UlaniKit/Tests/` | `UlaniKitTests`, `PaperhueUITests`, `UlaniSwiftCLITests` |
| `Paperhue/` | Xcode project: the app target is only an `@main` shell around `PaperhueUI`. `project.yml` is the XcodeGen spec that `Paperhue.xcodeproj` is generated from |
| `scripts/swift-test.sh` | Runs `swift test` for the package |
| `scripts/build-macos.sh` | Builds the release: `Paperhue.app`, universal, signed ad hoc, zipped |

## Protocol and shared test vectors

- [`shared/PROTOCOL.md`](../shared/PROTOCOL.md) describes the BLE protocol:
  GATT layout, commands, frame format, upload sequence, header-only probe and
  flow control.
- [`shared/vectors/ulani-vectors.json`](../shared/vectors/ulani-vectors.json)
  holds the test vectors both implementations must pass: CRCs, image headers,
  commands, reply parsing, packing, nearest-colour samples, two test frames and
  the push order. `VectorTests`, `ChecksumTests`, `FrameTests` and
  `FrameEncoderTests` read the file straight from the repo
  (`Tests/UlaniKitTests/VectorSupport.swift`), so there is no copy to keep in
  sync. Decoding and scaling a photo may differ from the Python output in
  single pixels; the dithering below does not.
- The vectors are generated from the Python implementation. When protocol
  behaviour changes, change the Python side too and regenerate them from the
  repo root: `python -m ulani_epaper.vectors shared/vectors/ulani-vectors.json`.

## Requirements

- Unit tests and `ulani-swift`: Xcode 16 or later, or just the Command Line
  Tools (Swift 6.0 or later).
- The app: Xcode 16 or later.
- Changing the Xcode project: [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  2.46.0 (CI pins this version; others may write a different project file).
- Integration tests and `--relay`: the Python package, installed as described
  in the [README](../README.md).

## Build and test

Run the commands from the repo root.

```bash
apple/scripts/swift-test.sh                       # all unit tests: UlaniKit, UI, ulani-swift
apple/scripts/swift-test.sh --filter PushTests    # other `swift test` options pass through
swift build --package-path apple/UlaniKit         # build only
```

Unit tests never touch Bluetooth: the push state machine runs against
`FakeLink`, and `CoreBluetoothLink` is tested without a radio. With only the
Command Line Tools installed, plain `swift test` fails with
`no such module 'Testing'`; `swift-test.sh` adds the missing search paths (with
Xcode it is plain `swift test`).

Integration tests run the whole push through the relay's fake device (CI
runs them too):

```bash
python -m ulani_epaper.relay --fake --refresh-seconds 2 &    # fake device on 127.0.0.1:8765
ULANI_RELAY=127.0.0.1:8765 apple/scripts/swift-test.sh --filter RelayIntegration
kill %1
```

Without `ULANI_RELAY` these tests are skipped. They push random images, so
they refuse a relay that is connected to a real device, and their timing
assumes `--refresh-seconds 2`.

The Keychain round trip (`FeedSecretTests.secretsRoundTripInTheKeychain`)
writes the default keychain, so it runs only with `PAPERHUE_KEYCHAIN_TEST=1`
and is skipped otherwise: a plain test run never writes your login keychain.
CI runs it in its own step, "Keychain round trip (temporary keychain)" in
`.github/workflows/apple.yml`: it creates `paperhue-ci.keychain-db` with a
random password, unlocks it with no auto-lock, puts it first in the search
list and makes it the default, runs
`apple/scripts/swift-test.sh --filter FeedSecretTests` with the variable set,
fails unless the output says the round trip passed (a skipped test passes
too), and then restores the previous default and search list and deletes the
temporary keychain. To run it on a Mac, do the same; never set the variable
while your login keychain is the default. Every test run checks that the
store's query never asks for the data protection keychain.

### The app

1. Create `apple/Paperhue/Config/Signing.local.xcconfig` (git-ignored) with
   your team ID, `DEVELOPMENT_TEAM = ABCDE12345`. Do not pick the team in
   Xcode's Signing & Capabilities pane: that edits the generated project.
2. `open apple/Paperhue/Paperhue.xcodeproj`, choose the `Paperhue`
   scheme and My Mac, and run.
3. Pair the Mac with the device: hold the device's button for about 5 s
   until the LED blinks green, then press 「讀取狀態」 (Read status) in the app; macOS should
   ask to pair (not yet tried with a real device).

An unsigned build, as CI does it:

```bash
xcodebuild -project apple/Paperhue/Paperhue.xcodeproj -scheme Paperhue \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Never change the project in Xcode (adding files, build settings, the team, or
"Update to recommended settings"). Edit `apple/Paperhue/project.yml`,
regenerate, and commit both; CI regenerates the project and fails on any
difference:

```bash
xcodegen generate --spec apple/Paperhue/project.yml
```

New Swift files under `UlaniKit/Sources/PaperhueUI/` need no project change.

### Release build

```bash
apple/scripts/build-macos.sh               # -> apple/build/release/Paperhue-macOS.zip
```

A universal (arm64 + x86_64) Release build of `Paperhue.app`, signed ad hoc
(`codesign -s -`) with the app's sandbox entitlements and zipped with
`ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent`: without those
options ditto stores extended attributes as AppleDouble `._*` entries, which
`unzip` extracts into the app and so breaks its signature. The script then
extracts the zip with `unzip` and fails unless that copy passes
`codesign --verify --deep --strict` and nothing in it is named ULANI (no file,
and none of the bundle's names or its identifier). CI runs the script and keeps
the zip as a workflow artifact.

The app's version (About, and the calendar requests' User-Agent) is
`MARKETING_VERSION` in `project.yml`, unless `PAPERHUE_VERSION` is set: on a
`v*` tag CI sets it from the tag (`v0.3.2` -> `0.3.2`), as the Android build
does, and the script fails if the built app says otherwise. Raise
`project.yml`'s version with each release so local builds match.

Without a Developer ID certificate the app is not notarized, so macOS refuses
the first launch of a downloaded copy. Users open it once and macOS remembers
the choice:

- macOS 14: right-click (or Control-click) `Paperhue.app` › 打開 (Open), then
  confirm.
- macOS 15 and later: try to open it once, then System Settings › 隱私權與安全性
  (Privacy & Security) › 強制打開 (Open Anyway) next to the Paperhue message,
  and confirm.

### ulani-swift

```bash
swift run --package-path apple/UlaniKit ulani-swift --help
swift run --package-path apple/UlaniKit ulani-swift info --relay 127.0.0.1:8765
swift run --package-path apple/UlaniKit ulani-swift push --relay 127.0.0.1:8765 1.jpg 2.jpg
swift run --package-path apple/UlaniKit ulani-swift probe --relay 127.0.0.1:8765 1.jpg 2.jpg
swift run --package-path apple/UlaniKit ulani-swift show --relay 127.0.0.1:8765 3     # put page 3 on screen
swift run --package-path apple/UlaniKit ulani-swift push --dry-run 1.jpg   # encode and print CRCs only
swift run --package-path apple/UlaniKit ulani-swift push --strength 0.5 --dry-run 1.jpg
swift run --package-path apple/UlaniKit ulani-swift push --crop 2=0.25,0.25,0.5,0.5 --dry-run 1.jpg 2.jpg
```

Without `--relay` the tool uses this Mac's Bluetooth (the Mac must be paired
with the device). To reach a device next to another computer, run
`python -m ulani_epaper.relay` there and forward its port with
`ssh -L 8765:127.0.0.1:8765 <that computer>`. `-v` logs every command and
reply (hex) to stderr.

## Photo dithering

The 顏色 (Colours) setting picks how photos are mapped to the panel's 7
colours: 自然 (Natural, the default) or 經典 (Classic). Photo pages, calendar
backgrounds and card photos use it, in the scheduled sync too. It is kept in
the settings as `"colours"`. Settings kept before it load once as 自然 at
標準 (`PageSettings.load`). Changing to 自然 sets 顆粒感 to 標準; 經典 keeps
it, and so does picking 自然 again. `ulani-swift` takes `--colours natural|classic` (default natural).

- 自然 (`Natural`) follows [`shared/DITHER.md`](../shared/DITHER.md)
  §4-§5, like Python's `image.natural`:
  - Each colour is mapped to what the panel can show, in linear light.
  - Serpentine Stucki error diffusion then matches it against the panel's
    measured colours, using black, white and the two inks either side of
    its hue.
  - It works in Doubles in the spec's order (swiftc fuses no multiply-add)
    and rounds nothing.
  - The tables are `shared/dither/natural-tables.json`, copied verbatim
    into `NaturalTables.swift`, because the app ships no resource bundle
    for UlaniKit. When the shared file changes, copy it in again;
    `NaturalTests` fails until then.
  - `NaturalTests` passes
    [`shared/vectors/natural-vectors.json`](../shared/vectors/natural-vectors.json)
    in full.
  - A frame takes about 30 ms on an M2 in a release build.
- 經典 is the Stucki encoder below, unchanged from 0.3.

`FrameEncoder` (經典) maps photos to the panel's 7 colours with Stucki error
diffusion on integer RGB, defined exactly like `stucki` in
`python/src/ulani_epaper/image.py`: weights out of 42, raster order, nearest
colour by squared distance (ties: lowest index), error spread as
`Int(error * weight / 42 * strength)` (truncated toward zero), and the
hue-keeping range rule `keepInRange`. So both give the same palette indices
for the same pixels. `strength` scales the spread error; the app's 顆粒感
(Grain) picker offers 標準 (Standard) 1.0, 柔和 (Soft) 0.8, 更柔和 (Softer) 0.65
and 最平滑 (Smoothest) 0.5, for both encoders, and `ulani-swift` takes
`--strength`.

Previews draw frames in the panel's measured colours
(`Palette.previewColours`), not the ideal ones the encoders match against.
`PanelImage` draws a preview shown smaller than 800x480 screen pixels as the
area-weighted mean, in linear light, of the frame pixels each screen pixel
covers. At that size or larger it uses nearest neighbour.

## Photo size and crop

- Photo size ([`shared/CROP.md`](../shared/CROP.md), "Photo size"): a photo
  of more than 50,000,000 pixels by its header is refused before anything is
  decoded (`PhotoTooLarge`; the app says 「照片超過 5000 萬像素的上限，請先縮小再選。」).
  Every other photo is decoded at its size capped to 3840x2160 after EXIF
  orientation (2160x3840 for a portrait one), aspect kept, never scaled up
  (`FrameEncoder.maxPhotoSize`, `cappedPhotoSize` with the shared integer
  rounding, `decodeSize`), so a crop zoomed in 8x stays sharp.
  `FrameEncoder.loadPhoto` returns the decoded image and that capped size
  (`DecodedPhoto.size`). `PhotoSizeTests` checks
  [`shared/vectors/photo-cap-vectors.json`](../shared/vectors/photo-cap-vectors.json).
- `Crop` is the part of the photo that fills the panel in cover mode
  ([`shared/CROP.md`](../shared/CROP.md)): left, top, width and height as
  fractions of the capped photo, with the panel's 800:480 shape.
  `Crop.centred` is what cover shows without one, `Crop.validated` checks one
  exactly like Python's `check_crop` (inside the photo, the shape within a
  pixel, at least 100 photo pixels high and at most 8x zoom:
  `Crop.minimumWidth`), and `Crop.box` rounds it half up into the pixels of
  the decoded image. `FrameEncoder.encode(_:fit:crop:...)` stretches that box
  over the panel; contain ignores the crop. No crop (nil) renders the centred
  cover exactly as before crops existed.
- `CropTests` checks every case of
  [`shared/vectors/crop-vectors.json`](../shared/vectors/crop-vectors.json),
  read from the repo like the other vectors. Only the crop maths are shared:
  the resampling differs between platforms.
- `ulani-swift push` and `probe` take `--crop PAGE=LEFT,TOP,WIDTH,HEIGHT`
  (repeatable) and check it against each photo; one that does not suit its
  photo is a usage error (exit status 2).
- In the app, 「調整範圍…」 (Adjust crop…) under a page, or a double-click on
  its preview, opens the crop editor: in Fill only, once the photo is decoded,
  never during a job (`PushViewModel.canAdjustCrop`). `CropEditorView` only
  draws and turns drags, corner handles, pinches, scrolling, the zoom slider
  and the arrow keys into calls of `CropGeometry`, which does the maths:
  moving, resizing about the opposite corner, zooming about a point, nudging
  1 % (Shift: 10 %), and clamping to the photo and to `Crop.minimumWidth`, so
  every frame it makes passes `Crop.validated` (`CropGeometryTests`). The view
  model keeps one crop per page, in memory only (`PageModel.crop`, nil for the
  centred default, which 重設 (Reset) goes back to): a new photo or a clear
  resets it, Fit ignores it but keeps it, and `setCrop` checks it against the
  capped size (`PageModel.photoSize`) and renders the page again.

## Page settings and sync

- `PageSettings` (`PaperhuePages/Sync/`) is what each page shows (`PageKind`:
  photo, month, agenda, todo, board, message; default 1 month, 2 agenda,
  3 to-do, 4 photo), the calendar sources (`Feed`: id, name, colour) and the
  daily sync times ("HH:MM", none by default), kept as JSON in UserDefaults
  under `pageSettings`, checked like Python's `Settings.validate`. A source's
  address lives only in the Keychain (`KeychainFeedSecrets`), and nothing
  read from a calendar is kept.
- `KeychainFeedSecrets` keeps one generic password per source (service
  `<bundle id>.ical-feed`, account = the feed id, the value
  `FeedSecret.json`) in the file-based (login) keychain, for every build.
  The data protection keychain needs a keychain access group, which only a
  provisioning profile from an Apple developer team can authorise (Apple
  TN3137); the release is signed ad hoc, so every call to it fails with
  OSStatus -34018 (errSecMissingEntitlement). File-based items are never
  synced to iCloud, and the login keychain is unlocked when the user logs in.
  macOS trusts the app that created an item, and an ad hoc signature changes
  with every version: after an update macOS asks once per calendar source
  whether Paperhue may use it (the user enters their Mac password and chooses
  Always Allow, 永遠允許). The scheduled sync runs the same executable, so it
  can be the one that asks when it reads an address first: its question names
  the executable, Paperhue, and the run waits for the answer (launchd starts
  no other run meanwhile). If the user cancels or denies (errSecUserCanceled,
  errSecAuthFailed), the error says to try again and choose Always Allow; any
  other failure shows its OSStatus. Every read can ask, so the sources list
  (`FeedsView`) reads each source's host once when it opens, never while
  drawing: reading it in `body` asked again on every redraw, and a denied
  question came straight back.
  `FeedSecretTests` checks the query in every run and does the round trip
  only with `PAPERHUE_KEYCHAIN_TEST=1` (see [Build and test](#build-and-test)).
- `PageSync.drawCalendar` fetches the feeds (with none, the public Taiwan
  holidays calendar, as on Windows) and draws the month, agenda and to-do
  pages; `drawBoards` draws the board pages from the saved notes, without
  network. `PageSync.sync` (立即同步 and the scheduled sync) draws the
  calendar pages and pushes them without switching the display, throwing
  before anything is pushed. Loader, secret store and clock are injected:
  `PageSyncTests` runs without network, Keychain or device.
- The app follows the desktop model. Editing (page kinds, photos, notes,
  sources) only saves and redraws the previews. 推送到裝置 sends every page
  with content in one connection; calendar pages that cannot be read are
  left out with a warning and the rest still goes. 更新這頁 does the same for
  one page.
- The daily schedule is off until the user adds a time and turns it on. That
  registers `io.github.markhhm.paperhue.sync.plist` (Contents/Library/
  LaunchAgents) with `SMAppService`. launchd then starts the app's own
  executable with `--scheduled-sync` every 15 minutes and at login.
  `ScheduledSync.run` syncs once a daily time has passed since the last
  check, so a time missed while asleep is made up once, and keeps the
  outcome for the dialog. To try it, set a time a few minutes ahead and
  watch `/usr/bin/log stream --predicate 'subsystem == "com.apple.xpc.launchd"'`
  (zsh has a `log` builtin), or run
  `Paperhue.app/Contents/MacOS/Paperhue --scheduled-sync` yourself.

### Scheduled sync after an update

Found on 0.4.0 (2026-10-15) with a throwaway app, sandboxed and signed ad hoc
like Paperhue, on macOS 26:

- When the agent is first registered, Background Task Management (BTM)
  keeps a record for it with a launch constraint for its executable. Without
  a Team ID ("Bundle identifiers from launchd plist ignored because the
  executable doesn't have a Team ID") that constraint is the cdhash of the
  build that registered it, and an ad hoc cdhash changes with every build.
- After an update, launchd's next start of the agent is killed before any of
  its code runs: SIGKILL (Code Signature Invalid), "Launch Constraint
  Violation", one crash report in `~/Library/Logs/DiagnosticReports`.
- launchd's start after that is a repair ("Requesting repair LWCR update"):
  BTM replaces the record with one for the new build (and macOS shows "Paperhue
  can run in the background" again), but launchd's job still names the old
  record, so that start and every later one exit 78 (EX_CONFIG), without
  crash reports. `SMAppService.status` stays `.enabled` throughout.
- `register()` alone changes nothing. `unregister()` then `register()` hands
  launchd a new job, and that works only after the repair: before it, the new
  job gets the old record again and is killed, and the repair the replaced
  job was due for is lost. Changing the agent's plist does not renew the record either.
  `sfltool dumpbtm` lists the records; `launchctl print
  gui/$UID/io.github.markhhm.paperhue.sync` shows `needs LWCR update`, the runs
  and the last exit.

How the app recovers:

- `--scheduled-sync` first notes when it ran (`scheduledSyncLastRun`), even
  when nothing is due or the settings cannot be read.
- At launch and whenever it becomes active, with a schedule on, the app
  registers the agent afresh (`SyncAgent.register` unregisters an enabled
  agent first) when it has not run for 35 minutes. launchd starts it every 15
  minutes while the Mac is awake, so by then it has usually had its repair.
  After a successful registration the app waits another 35 minutes
  (`scheduledSyncLastRegister`): registering again sooner would throw away the
  repair. A failed one is tried again at the next check. Without any heartbeat
  yet (every install up to 0.4.0) the 35 minutes start at the app's first check
  (`scheduledSyncWatchingSince`). Nothing happens while the agent waits for the
  user's approval in Login Items.
- The 35 minutes are wall-clock time, and launchd skips its starts while the
  Mac sleeps. After a sleep the app may register a healthy agent again, which
  is harmless: BTM keeps its record, so macOS shows no notification. If the
  Mac slept after an update before launchd's repair, the app may register too
  early. That costs one more round (another killed start), and a check at
  least 35 minutes later, with the Mac awake for 15 of them, recovers.
- 啟用／更新排程 registers afresh too and keeps the times. It also ends a
  scheduled sync that is running at that moment; the start that follows the
  registration runs it again. 每日排程 shows when the agent last ran, and asks
  for 啟用／更新排程 when it has not run for an hour (not within 35 minutes of a
  registration, nor while approval is pending).
- So after an update the schedule pauses until the agent has missed two
  starts and the app is opened or brought to the front. A Developer ID (Team
  ID) signature should pin the record to the team and bundle id instead of the
  cdhash; that has not been tried.

## Languages

The app starts in the language macOS picks for its menus: the first
preferred language it has a localization for, so Chinese for any Chinese
script or region and English when none matches. The button in the window's
toolbar, named after the other language ("English" / "中文"), switches every
text in the window at once, also during a push. The choice is kept in the
app's own `AppleLanguages` (UserDefaults), the key that System Settings ›
General › Language & Region › Applications sets for Paperhue too, so there is
one choice and the last one made wins.

- All texts live in `UlaniKit/Sources/PaperhueUI/Strings.swift`.
  `Strings(language)[key]` gives a fixed text: `Strings.Key` lists them and one
  exhaustive `switch` gives each in both languages. Texts with numbers or
  names are methods (`pushDone`, `syncDone`, `deviceStatus`, `hint`, ...)
  that also cover both. The Chinese mirrors the Windows app: keep it word for
  word. Call the hardware the device (裝置), never a calendar.
- The view model keeps state, not text (`Summary`, `DeviceStatus`,
  `PageStatus`, `LogEntry`, `Alert`); the views render it with
  `model.strings`, so no text in the window stays in the old language after a
  switch.
- To add a text, add a `Key` case and its line in the `switch` (a key without
  both texts does not compile), or a method for a formatted text. The
  key-parity test (`KeyParityTests`) checks every key: both texts non-empty,
  Chinese characters in the Chinese, no CJK characters or punctuation in the
  English.
- System-provided UI (the menu bar, the photo and file pickers, the Bluetooth
  prompt) uses the localization macOS picks at launch from
  `Paperhue/en.lproj`, `zh-Hant.lproj` and `zh-Hans.lproj` (only the app name,
  so Simplified Chinese systems get Chinese menus too), English when none
  matches (`developmentLanguage: en`). `Language.systemDefault` makes the same
  pick (`Bundle.preferredLocalizations`) from `Language.localizations`, which
  must list the same folders (`LanguageTests` checks it), so the window and
  the menus start in the same language.
- macOS does not relocalize the menu bar while the app runs: after a switch it
  stays in the launch language until the next launch, and the window says so
  in a line at the top (`menusNextLaunch`) until the user switches back.

## Status

- The protocol, frame encoder, push state machine, connector, relay link,
  `ulani-swift` and the interface are covered by unit tests, and every shared
  vector passes.
- Through the relay, UlaniKit has driven a real device: a four-page push
  (page on screen last), a header-only probe of every page, a repeated push
  that found every page unchanged, and a push started during the panel
  refresh, which waited and then succeeded.
- `CoreBluetoothLink`, the Mac's own Bluetooth link, has not yet run against a
  real device: connecting, pairing and GATT access are only covered by tests
  without a radio.
- The crop editor's mouse, trackpad and keyboard handling has not been tried by
  hand yet: its maths are covered by `CropGeometryTests`, the crop state by
  `PageCropTests`.
- Open question: how many bonds the firmware keeps (pairing the Mac may drop
  another computer's bond).
- Calendar recurrence (`ICal.parse`, `RecurrenceRule`) follows dateutil except on purpose here: an event whose RRULE uses SECONDLY, MINUTELY, HOURLY, BYWEEKNO, BYYEARDAY, BYHOUR, BYMINUTE or BYSECOND (or an INTERVAL below 1, which dateutil may never finish) is skipped and counted as skipped, not expanded.
