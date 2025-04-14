// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PartoutSupport",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "PartoutSupport",
            targets: ["PartoutSupport"]
        )
    ],
    dependencies: [
        .package(path: "../PartoutAPI")
    ],
    targets: [
        .target(
            name: "PartoutSupport",
            dependencies: ["PartoutAPI"]
        ),
        .testTarget(
            name: "PartoutSupportTests",
            dependencies: ["PartoutSupport"]
        )
    ]
)
