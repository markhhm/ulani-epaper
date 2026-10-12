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
```

Without `--relay` the tool uses this Mac's Bluetooth (the Mac must be paired
with the device). To reach a device next to another computer, run
`python -m ulani_epaper.relay` there and forward its port with
`ssh -L 8765:127.0.0.1:8765 <that computer>`. `-v` logs every command and
reply (hex) to stderr.

## Photo dithering

`FrameEncoder` maps photos to the panel's 7 colours with Stucki error
diffusion on integer RGB, defined exactly like `stucki` in
`python/src/ulani_epaper/image.py`: weights out of 42, raster order, nearest
colour by squared distance (ties: lowest index), error spread as
`Int(error * weight / 42 * strength)` (truncated toward zero), and the
hue-keeping range rule `keepInRange`. So both give the same palette indices
for the same pixels. `strength` scales the spread error; the app's 顆粒感
(Grain) picker offers 標準 (Standard) 1.0, 柔和 (Soft) 0.8, 更柔和 (Softer) 0.65
and 最平滑 (Smoothest) 0.5, and `ulani-swift` takes `--strength`.

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
  names are methods (`pushDone`, `verifyDone`, `deviceStatus`, `hint`, ...)
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
- Open question: how many bonds the firmware keeps (pairing the Mac may drop
  another computer's bond).
