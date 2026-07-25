// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShannonPill",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ShannonPill", targets: ["ShannonPill"]),
        .library(name: "PillCore", targets: ["PillCore"]),
        .library(name: "AgentReaders", targets: ["AgentReaders"]),
        .library(name: "DevServers", targets: ["DevServers"]),
        .library(name: "Routes", targets: ["Routes"]),
    ],
    dependencies: [
        .package(path: "../Packages/ShannonTheme"),
        .package(path: "../Packages/ShannonCore"),
    ],
    targets: [
        .target(
            name: "PillCore",
            dependencies: [
                .product(name: "ShannonTheme", package: "ShannonTheme"),
                .product(name: "ShannonCore", package: "ShannonCore"),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
            ]
        ),
        // W1 — vendor artifact readers (Claude Code, Codex, …)
        .target(name: "AgentReaders", dependencies: ["PillCore"]),
        // W3 — local dev server discovery
        .target(name: "DevServers", dependencies: ["PillCore"]),
        // W4 — Quick Routes + Fast Actions
        .target(name: "Routes", dependencies: ["PillCore"]),
        // Declared empty for future streams (W2 / W5 / Views)
        .target(name: "UsageCore", dependencies: ["PillCore"]),
        .target(name: "Workspaces", dependencies: ["PillCore"]),
        .target(name: "Surfaces", dependencies: ["PillCore"]),
        .executableTarget(
            name: "ShannonPill",
            dependencies: [
                "PillCore",
                "AgentReaders",
                "DevServers",
                "Routes",
                "UsageCore",
                "Workspaces",
                "Surfaces",
                .product(name: "ShannonTheme", package: "ShannonTheme"),
                .product(name: "ShannonCore", package: "ShannonCore"),
            ]
        ),
        .testTarget(
            name: "PillCoreTests",
            dependencies: [
                "PillCore",
                "AgentReaders",
                "DevServers",
                "Routes",
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        // Covers the app target's own wiring. PillCoreTests can only reach the
        // extracted policy types (`EntropyProvenance`, `PillPanelHeight`,
        // `ConfirmationCreatedAtResolver`); every defect those types were
        // extracted for actually lived at a CALL SITE in ShannonPill, and a
        // call site that stops calling them still leaves PillCoreTests green.
        .testTarget(name: "ShannonPillTests", dependencies: ["ShannonPill"]),
    ]
)
