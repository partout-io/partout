// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "partout-shared",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "PartoutCore",
            targets: ["PartoutCore"]
        ),
        .library(
            name: "PartoutCore_C",
            targets: ["PartoutCore_C"]
        )
    ],
    targets: [
        .target(
            name: "PartoutCore",
            dependencies: ["PartoutCore_C"],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"])
            ]
        ),
        .target(
            name: "PartoutCore_C"
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: ["PartoutCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
