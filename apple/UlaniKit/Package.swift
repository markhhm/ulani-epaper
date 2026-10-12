// swift-tools-version: 6.0
import PackageDescription

// The package is named Paperhue, not after its first target: SwiftPM names a target's resource
// bundle `<package>_<target>.bundle`, and every bundle a dependency of the app has ships inside
// Paperhue.app, where no file name may say ULANI (apple/scripts/build-macos.sh checks this).
let package = Package(
    name: "Paperhue",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UlaniKit", targets: ["UlaniKit"]),
        .library(name: "PaperhueAgenda", targets: ["PaperhueAgenda"]),
        .library(name: "PaperhuePages", targets: ["PaperhuePages"]),
        .library(name: "PaperhueUI", targets: ["PaperhueUI"]),
        .executable(name: "ulani-swift", targets: ["ulani-swift"]),
    ],
    targets: [
        .target(name: "UlaniKit"),
        // Calendar and message data: the agenda model, iCal parsing and recurrence, calendar
        // sources, notes. No UI and no drawing.
        .target(name: "PaperhueAgenda"),
        // Calendar and message board pages: bundled fonts, text rules, drawing, the page kinds.
        .target(name: "PaperhuePages", dependencies: ["UlaniKit", "PaperhueAgenda"],
                resources: [.copy("Fonts")]),
        .target(name: "PaperhueUI", dependencies: ["UlaniKit"]),
        .executableTarget(name: "ulani-swift", dependencies: ["UlaniKit"]),
        .testTarget(name: "UlaniKitTests", dependencies: ["UlaniKit"]),
        .testTarget(name: "PaperhueAgendaTests", dependencies: ["PaperhueAgenda"]),
        .testTarget(name: "PaperhuePagesTests", dependencies: ["PaperhuePages", "PaperhueAgenda", "UlaniKit"]),
        .testTarget(name: "PaperhueUITests", dependencies: ["PaperhueUI"]),
        .testTarget(name: "UlaniSwiftCLITests", dependencies: ["ulani-swift", "UlaniKit"]),
    ]
)
