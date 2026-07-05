// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "YSwift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "YSwift", targets: ["YSwift"]),
    ],
    targets: [
        // Phase 1/2 public API + engine seam. Currently backed by a stub engine;
        // Phase 1 adds a `YrsEngine` over the `yffi` C ABI (a `CYrs` systemLibrary target).
        .target(
            name: "YSwift",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "YSwiftTests",
            dependencies: ["YSwift"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
