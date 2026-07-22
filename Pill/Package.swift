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
        .target(name: "PillCore"),
        .executableTarget(
            name: "ShannonPill",
            dependencies: [
                "PillCore",
                .product(name: "ShannonTheme", package: "ShannonTheme"),
                .product(name: "ShannonCore", package: "ShannonCore"),
            ]
        ),
        .testTarget(name: "PillCoreTests", dependencies: ["PillCore"]),
    ]
)
