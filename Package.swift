// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let version = "0.155.2"

let package = Package(
    name: "partout",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "partout",
            targets: ["Partout"]
        ),
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
        .binaryTarget(
            name: "PartoutNative",
            url: "https://github.com/partout-io/partout/releases/download/\(version)/PartoutNative.xcframework.zip",
            checksum: "f09ddaf15ceda59129e33568c43592f852dae88246500a3d55d5e346199685e1"
        ),
        .target(
            name: "Partout",
            dependencies: [
                "PartoutCore",
                "PartoutNative"
            ],
            path: "cross/apple/Sources/Partout"
        ),
        .target(
            name: "PartoutCore",
            dependencies: ["PartoutCore_C"],
            path: "cross/apple/Sources/PartoutCore"
        ),
        .target(
            name: "PartoutCore_C",
            path: "cross/apple/Sources/PartoutCore_C"
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: ["PartoutCore"],
            path: "cross/apple/Tests/PartoutTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
