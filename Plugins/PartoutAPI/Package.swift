// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PartoutAPI",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "PartoutAPI",
            targets: ["PartoutAPI"]
        )
    ],
    dependencies: [
        .package(path: "../../Core"),
        .package(url: "https://github.com/iwill/generic-json-swift", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "PartoutAPI",
            dependencies: [
                .product(name: "GenericJSON", package: "generic-json-swift"),
                .product(name: "PartoutCore", package: "Core")
            ]
        ),
        .testTarget(
            name: "PartoutAPITests",
            dependencies: ["PartoutAPI"],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
