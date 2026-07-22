// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShannonCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "ShannonCore", targets: ["ShannonCore"]),
    ],
    targets: [
        .target(
            name: "ShannonCore",
            swiftSettings: [
                // Strict concurrency: every shared type must prove it is
                // Sendable, which is what keeps CloudKit and WatchConnectivity
                // callbacks off the main actor by construction.
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(name: "ShannonCoreTests", dependencies: ["ShannonCore"]),
    ]
)
