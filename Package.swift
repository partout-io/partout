// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PassepartoutKit-Binary",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "PassepartoutKit-Binary",
            targets: ["Target"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "Target",
            url: "https://github.com/passepartoutvpn/passepartoutkit/releases/download/0.99.5/PassepartoutKit.xcframework.zip",
            checksum: "2e0b6dec16642cc69c64a56d3768aa91215e8baa9d1ad3d05700dd50e84eb0f6"
        ),
        .testTarget(
            name: "TargetTests",
            dependencies: ["Target"]
        )
    ]
)
