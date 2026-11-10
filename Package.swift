// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Parvus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Parvus",
            path: "Sources/Parvus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
