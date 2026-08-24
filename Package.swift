// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

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
        .target(
            name: "PartoutCore",
            dependencies: ["PartoutCore_C"],
            path: "cross/apple/Sources/PartoutCore"
        ),
        .target(
            name: "PartoutCore_C",
            path: "cross/apple/Sources/PartoutCore_C"
        ),
        .target(
            name: "PartoutNative_C",
            path: "cross/apple/Sources/PartoutNative_C"
        ),
        .target(
            name: "PartoutRuntime",
            dependencies: [
                "PartoutCore",
                "PartoutNative_C"
            ],
            path: "cross/apple/Sources/PartoutRuntime"
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: ["PartoutCore"],
            path: "cross/apple/Tests/PartoutTests"
        )
//        .testTarget(
//            name: "PartoutRuntimeTests",
//            dependencies: ["PartoutRuntime"],
//            path: "cross/apple/Tests/PartoutRuntimeTests"
//        )
    ],
    swiftLanguageModes: [.v6]
)
