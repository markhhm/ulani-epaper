# Paperhue for macOS: developer notes

The Swift side of Paperhue (紙彩): a Swift package with the protocol, frame
encoder and push logic, the SwiftUI interface, a command-line tool for testing,
and the Xcode project that turns the interface into the macOS app. The
interface is in Traditional Chinese (zh-TW) and behaves like the Windows app
(`python/src/ulani_epaper/gui.py`): pick up to four photos and put them on
pages 1-4 of a ULANI e-paper device.

## What is here

| Path | What |
|---|---|
| `UlaniKit/` | Swift package (`swift-tools-version` 6.0) |
| `UlaniKit/Sources/UlaniKit/` | Library, no UI: messages and CRCs (`Protocol/`), frame encoder (`Image/`), session, connector and push state machine (`Session/`), CoreBluetooth and relay links (`Transport/`) |
| `UlaniKit/Sources/PaperhueUI/` | SwiftUI interface, view model and all user-facing text (`Strings.swift`); nearly all of the app's code lives here |
| `UlaniKit/Sources/ulani-swift/` | macOS command-line tool (`info`, `push`, `probe`) for trying UlaniKit over Bluetooth or the relay |
| `UlaniKit/Tests/` | `UlaniKitTests`, `PaperhueUITests`, `UlaniSwiftCLITests` |
| `Paperhue/` | Xcode project: the app target is only an `@main` shell around `PaperhueUI`. `project.yml` is the XcodeGen spec that `Paperhue.xcodeproj` is generated from |
| `scripts/swift-test.sh` | Runs `swift test` for the package |

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
  sync. Photo encoding beyond the vectors does not have to match the Python
  output pixel for pixel.
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
   until the LED blinks green, then press 「讀取狀態」 in the app; macOS should
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

### ulani-swift

```bash
swift run --package-path apple/UlaniKit ulani-swift --help
swift run --package-path apple/UlaniKit ulani-swift info --relay 127.0.0.1:8765
swift run --package-path apple/UlaniKit ulani-swift push --relay 127.0.0.1:8765 1.jpg 2.jpg
swift run --package-path apple/UlaniKit ulani-swift probe --relay 127.0.0.1:8765 1.jpg 2.jpg
swift run --package-path apple/UlaniKit ulani-swift push --dry-run 1.jpg   # encode and print CRCs only
```

Without `--relay` the tool uses this Mac's Bluetooth (the Mac must be paired
with the device). To reach a device next to another computer, run
`python -m ulani_epaper.relay` there and forward its port with
`ssh -L 8765:127.0.0.1:8765 <that computer>`. `-v` logs every command and
reply (hex) to stderr.

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
