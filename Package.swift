// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lumac",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "lumac",
            path: "Sources/lumac",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
