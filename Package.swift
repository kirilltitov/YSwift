// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "YSwift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "YSwift", targets: ["YSwift"])
    ],
    targets: [
        // Public API + pure-Swift CRDT implementation.
        .target(
            name: "YSwift",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "YSwiftTests",
            dependencies: ["YSwift"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Micro-benchmarks over the public API.
        .executableTarget(
            name: "YSwiftBench",
            dependencies: ["YSwift"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
