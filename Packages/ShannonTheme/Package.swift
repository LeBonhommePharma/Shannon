// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShannonTheme",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "ShannonTheme", targets: ["ShannonTheme"]),
    ],
    targets: [
        .target(name: "ShannonTheme"),
        .testTarget(name: "ShannonThemeTests", dependencies: ["ShannonTheme"]),
    ]
)
