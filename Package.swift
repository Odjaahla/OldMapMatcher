// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OldMapMatcher",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "OldMapMatcher", targets: ["OldMapMatcher"]),
        .library(name: "MapMatchCore", targets: ["MapMatchCore"]),
        .library(name: "MapLayers", targets: ["MapLayers"]),
    ],
    targets: [
        // Pure math: projections, transform fitting, diagnostics. No UI dependencies.
        .target(name: "MapMatchCore"),
        // Warping old maps onto MapKit and the export format shared by the Mac and iPhone apps.
        .target(name: "MapLayers", dependencies: ["MapMatchCore"]),
        .executableTarget(name: "OldMapMatcher", dependencies: ["MapMatchCore", "MapLayers"]),
        .testTarget(name: "MapMatchCoreTests", dependencies: ["MapMatchCore", "MapLayers"]),
    ]
)
