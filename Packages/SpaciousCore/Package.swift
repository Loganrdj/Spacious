// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaciousCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpaciousCore", targets: ["SpaciousCore"]),
    ],
    targets: [
        .target(name: "SpaciousCore"),
        .testTarget(name: "SpaciousCoreTests", dependencies: ["SpaciousCore"]),
    ]
)
