// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShannonPill",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ShannonPill", targets: ["ShannonPill"]),
        .library(name: "PillCore", targets: ["PillCore"]),
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
        .executableTarget(
            name: "ShannonPill",
            dependencies: [
                "PillCore",
                .product(name: "ShannonTheme", package: "ShannonTheme"),
                .product(name: "ShannonCore", package: "ShannonCore"),
            ]
        ),
        .testTarget(name: "PillCoreTests", dependencies: ["PillCore"]),
        // Covers the app target's own wiring. PillCoreTests can only reach the
        // extracted policy types (`EntropyProvenance`, `PillPanelHeight`,
        // `ConfirmationCreatedAtResolver`); every defect those types were
        // extracted for actually lived at a CALL SITE in ShannonPill, and a
        // call site that stops calling them still leaves PillCoreTests green.
        .testTarget(name: "ShannonPillTests", dependencies: ["ShannonPill"]),
    ]
)
