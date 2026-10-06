// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MagentOverlay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "magent-overlay", targets: ["MagentOverlay"]),
    ],
    targets: [
        .executableTarget(
            name: "MagentOverlay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MagentOverlayTests",
            dependencies: ["MagentOverlay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
