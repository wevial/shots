// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Shots",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Shots", targets: ["Shots"]),
        .library(name: "ShotsKit", targets: ["ShotsKit"]),
    ],
    targets: [
        .target(
            name: "ShotsKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Shots",
            dependencies: ["ShotsKit"]
        ),
        .testTarget(
            name: "ShotsKitTests",
            dependencies: ["ShotsKit"],
            // Loaded via #filePath at test time, so SwiftPM shouldn't bundle them.
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
