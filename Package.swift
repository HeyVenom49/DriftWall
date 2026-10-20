// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Driftwall",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Driftwall", targets: ["Driftwall"]),
        .library(name: "DriftwallCore", targets: ["DriftwallCore"]),
    ],
    targets: [
        // Platform-independent domain logic, persistence, search, rotation and media processing.
        .target(
            name: "DriftwallCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The AppKit/SwiftUI application: UI, desktop playback surfaces, display + system integration.
        .executableTarget(
            name: "Driftwall",
            dependencies: ["DriftwallCore"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("IOKit")]
        ),
        // Build-time tool that renders the original, procedurally generated sample wallpapers.
        .executableTarget(name: "SampleMediaGenerator"),
        .testTarget(name: "DriftwallCoreTests", dependencies: ["DriftwallCore"]),
    ],
    swiftLanguageModes: [.v5]
)
