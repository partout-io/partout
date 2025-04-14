// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PartoutNE",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "PartoutNE",
            targets: ["PartoutNE"]
        )
    ],
    dependencies: [
        .package(path: "../../Core")
    ],
    targets: [
        .target(
            name: "PartoutNE",
            dependencies: [
                .product(name: "PartoutCore", package: "Core")
            ]
        ),
        .testTarget(
            name: "PartoutNETests",
            dependencies: ["PartoutNE"]
        )
    ]
)
