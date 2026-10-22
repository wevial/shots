// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Shots",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Shots", targets: ["Shots"]),
        // Named `shots-cli` here because `Shots` and `shots` would be the same file in the
        // build folder on a case-insensitive volume. build-app.sh copies it to
        // Shots.app/Contents/Helpers/shots.
        .executable(name: "shots-cli", targets: ["ShotsCommand"]),
        .library(name: "ShotsKit", targets: ["ShotsKit"]),
        .library(name: "ShotsCore", targets: ["ShotsCore"]),
    ],
    targets: [
        // Config, index, file handling, classification and the pipeline. Foundation, SQLite
        // and CryptoKit only, so all of it is testable without touching macOS services.
        .target(
            name: "ShotsCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The macOS side: Vision OCR, app context, xattrs, Finder tags, pasteboard,
        // permissions and Foundation Models. Implements ShotsCore's `Native` protocol.
        .target(
            name: "ShotsNative",
            dependencies: ["ShotsCore"]
        ),
        .target(
            name: "ShotsKit",
            dependencies: ["ShotsCore", "ShotsNative"]
        ),
        .executableTarget(
            name: "Shots",
            dependencies: ["ShotsKit", "ShotsCore"]
        ),
        .executableTarget(
            name: "ShotsCommand",
            dependencies: ["ShotsCore", "ShotsNative"]
        ),
        .testTarget(
            name: "ShotsCoreTests",
            dependencies: ["ShotsCore", "ShotsNative"],
            exclude: ["Fixtures"]
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
