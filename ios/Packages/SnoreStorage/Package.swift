// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnoreStorage",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SnoreStorage", targets: ["SnoreStorage"])
    ],
    dependencies: [
        .package(path: "../SnoreCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SnoreStorage",
            dependencies: [
                "SnoreCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            // Copy of spec/schema/v1.sql — SchemaSyncTests asserts it is
            // byte-identical to the normative file in spec/.
            resources: [.copy("Resources/v1.sql")]
        ),
        .testTarget(name: "SnoreStorageTests", dependencies: ["SnoreStorage"]),
    ]
)
