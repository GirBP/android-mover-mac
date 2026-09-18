// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidMover",
    // String Catalog (Sources/AndroidMover/Resources/Localizable.xcstrings) — джерело
    // "uk", жодних EN-перекладів поки нема (лише інфраструктура).
    defaultLocalization: "uk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "AndroidMoverCore",
            path: "Sources/AndroidMoverCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AndroidMover",
            dependencies: ["AndroidMoverCore"],
            path: "Sources/AndroidMover",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "amctl",
            dependencies: ["AndroidMoverCore"],
            path: "Sources/amctl",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AndroidMoverCoreTests",
            dependencies: ["AndroidMoverCore"],
            path: "Tests/AndroidMoverCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
