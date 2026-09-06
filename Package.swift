// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuMon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MenuMon",
            path: "Sources/MenuMon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
