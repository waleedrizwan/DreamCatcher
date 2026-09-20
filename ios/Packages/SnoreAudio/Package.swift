// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnoreAudio",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SnoreAudio", targets: ["SnoreAudio"])
    ],
    dependencies: [
        .package(path: "../SnoreCore"),
        .package(path: "../SnoreStorage"),
    ],
    targets: [
        // The platform adapter layer (spec §0.1): everything that touches
        // AVFoundation/SoundAnalysis lives here, behind protocols that
        // SnoreCore's pure logic never sees.
        .target(
            name: "SnoreAudio",
            dependencies: ["SnoreCore", "SnoreStorage"],
            resources: [
                // Precompiled (`coremlcompiler compile`) so SwiftPM and Xcode
                // ship the same bytes; regenerate with tools/yamnet/.
                .copy("Resources/YAMNet.mlmodelc"),
                .copy("Resources/yamnet_class_map.csv"),
            ]),
        .testTarget(name: "SnoreAudioTests", dependencies: ["SnoreAudio"]),
    ]
)
