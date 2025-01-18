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
            url: "https://github.com/passepartoutvpn/passepartoutkit/releases/download/0.99.4/PassepartoutKit.xcframework.zip",
            checksum: "90cbc3c866d4d8da5340dd43618161675b661806eabb132e1b6c914867bbd692"
        ),
        .testTarget(
            name: "TargetTests",
            dependencies: ["Target"]
        )
    ]
)
