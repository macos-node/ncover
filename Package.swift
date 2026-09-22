// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ncover",
    platforms: [.macOS(.v14)],
    targets: [
        // The rules live here, apart from the UI, so they can be tested without
        // a window and diffed against the GTK app that specified them.
        .target(name: "NCoverKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ncover",
            dependencies: ["NCoverKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NCoverKitTests",
            dependencies: ["NCoverKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
