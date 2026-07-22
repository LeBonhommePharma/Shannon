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
        .target(name: "ShannonCore"),
        .testTarget(name: "ShannonCoreTests", dependencies: ["ShannonCore"]),
    ]
)
