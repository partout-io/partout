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
            targets: ["PartoutRuntime"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "PartoutNative",
            url: "https://github.com/partout-io/partout/releases/download/\(version)/PartoutNative.xcframework.zip",
            checksum: "f09ddaf15ceda59129e33568c43592f852dae88246500a3d55d5e346199685e1"
        ),
        .target(
            name: "PartoutRuntime",
            dependencies: ["PartoutNative"],
            path: "cross/apple/Sources/PartoutRuntime"
        ),
        .testTarget(
            name: "PartoutRuntimeTests",
            path: "cross/apple/Tests/PartoutRuntimeTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
