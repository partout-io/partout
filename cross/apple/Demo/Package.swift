// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DemoRuntime",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "DemoRuntime",
            targets: ["DemoRuntime"]
        ),
    ],
    dependencies: [
        .package(path: "../../..")
    ],
    targets: [
        .target(
            name: "DemoRuntime",
            dependencies: [
                .product(name: "PartoutRuntime", package: "partout"),
                "PartoutNative"
            ],
            path: "Runtime"
        ),
        .binaryTarget(
            name: "PartoutNative",
            url: "https://github.com/partout-io/partout/releases/download/0.163.0/PartoutNative.xcframework.zip",
            checksum: "7166379d6977d784b40bb86a4f8fa9a11d044eb0569a318a431fe14cf7201b20"
        )
    ],
    swiftLanguageModes: [.v6]
)
