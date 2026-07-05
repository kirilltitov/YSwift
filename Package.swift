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
        // C ABI over the Rust `yrs` CRDT (the `cyrs` crate under rust/cyrs).
        // The static library must be built first: `cargo build --release` in rust/cyrs.
        .systemLibrary(name: "CYrs", path: "Sources/CYrs"),

        // Phase 1/2 public API + engine seam, backed by YrsEngine (Yrs facade).
        .target(
            name: "YSwift",
            dependencies: ["CYrs"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .unsafeFlags(["-Lrust/cyrs/target/release", "-lcyrs"]),
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
