// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UlaniKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UlaniKit", targets: ["UlaniKit"]),
        .library(name: "PaperhueUI", targets: ["PaperhueUI"]),
        .executable(name: "ulani-swift", targets: ["ulani-swift"]),
    ],
    targets: [
        .target(name: "UlaniKit"),
        .target(name: "PaperhueUI", dependencies: ["UlaniKit"]),
        .executableTarget(name: "ulani-swift", dependencies: ["UlaniKit"]),
        .testTarget(name: "UlaniKitTests", dependencies: ["UlaniKit"]),
        .testTarget(name: "PaperhueUITests", dependencies: ["PaperhueUI"]),
        .testTarget(name: "UlaniSwiftCLITests", dependencies: ["ulani-swift", "UlaniKit"]),
    ]
)
