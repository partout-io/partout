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
        .package(path: "../../Core"),
        .package(url: "https://github.com/iwill/generic-json-swift", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "PartoutAPI",
            dependencies: [
                .product(name: "GenericJSON", package: "generic-json-swift"),
                .product(name: "PartoutCore", package: "Core"),
                "PartoutPlatform"
            ]
        ),
        .target(
            name: "PartoutNE",
            dependencies: [
                .product(name: "PartoutCore", package: "Core")
            ]
        ),
        .target(
            name: "PartoutPlatform",
            dependencies: [
                .target(name: "_PartoutPlatformApple", condition: .when(platforms: [.iOS, .macOS, .tvOS])),
                .target(name: "PartoutNE", condition: .when(platforms: [.iOS, .macOS, .tvOS]))
            ]
        ),
        .target(
            name: "_PartoutPlatformApple",
            dependencies: [
                .product(name: "PartoutCore", package: "Core")
            ]
        ),
        .target(
            name: "PartoutSupport",
            dependencies: [
                "PartoutAPI",
                "PartoutPlatform"
            ]
        ),
        .testTarget(
            name: "PartoutAPITests",
            dependencies: ["PartoutAPI"],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "PartoutNETests",
            dependencies: ["PartoutNE"]
        ),
        .testTarget(
            name: "PartoutPlatformAppleTests",
            dependencies: ["_PartoutPlatformApple"]
        ),
        .testTarget(
            name: "PartoutSupportTests",
            dependencies: ["PartoutSupport"]
        )
    ]
)
