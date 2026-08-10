// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnoreCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SnoreCore", targets: ["SnoreCore"])
    ],
    targets: [
        // Pure Swift. No AVFoundation, no UIKit — everything here is
        // platform-free and unit-testable, per spec/SHARED_BEHAVIOR_SPEC.md.
        .target(name: "SnoreCore"),
        .testTarget(name: "SnoreCoreTests", dependencies: ["SnoreCore"]),
    ]
)
