// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "shots-helper",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "shots-helper",
            path: "Sources/shots-helper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
