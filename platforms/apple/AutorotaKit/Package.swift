// swift-tools-version: 5.9
// AutorotaKit: Swift Package wrapping the autorota-ffi Rust library.
//
// The XCFramework at XCFrameworks/AutorotaFFI.xcframework must be built first:
//   bash scripts/build_xcframework.sh          (from workspace root)

import PackageDescription

let package = Package(
    name: "AutorotaKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AutorotaKit", targets: ["AutorotaKit"]),
    ],
    targets: [
        // Swift ergonomics layer + generated UniFFI bindings
        .target(
            name: "AutorotaKit",
            dependencies: ["AutorotaFFI"],
            path: "Sources/AutorotaKit"
        ),
        // Pre-built XCFramework (produced by scripts/build_xcframework.sh)
        .binaryTarget(
            name: "AutorotaFFI",
            path: "XCFrameworks/AutorotaFFI.xcframework"
        ),
    ]
)
