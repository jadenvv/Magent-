// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MagentVM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "magent-vm", targets: ["MagentVM"]),
    ],
    targets: [
        .executableTarget(
            name: "MagentVM",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MagentVMTests",
            dependencies: ["MagentVM"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
