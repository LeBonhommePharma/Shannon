// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShannonPill",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ShannonPill", targets: ["ShannonPill"]),
        .library(name: "PillCore", targets: ["PillCore"]),
    ],
    targets: [
        .target(name: "PillCore"),
        .executableTarget(name: "ShannonPill", dependencies: ["PillCore"]),
        .testTarget(name: "PillCoreTests", dependencies: ["PillCore"]),
    ]
)
