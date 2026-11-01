// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OldMapMatcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OldMapMatcher", targets: ["OldMapMatcher"]),
        .library(name: "MapMatchCore", targets: ["MapMatchCore"]),
    ],
    targets: [
        // Pure math: projections, transform fitting, diagnostics. No UI dependencies.
        .target(name: "MapMatchCore"),
        .executableTarget(name: "OldMapMatcher", dependencies: ["MapMatchCore"]),
        .testTarget(name: "MapMatchCoreTests", dependencies: ["MapMatchCore"]),
    ]
)
