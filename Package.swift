// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let filename = "Partout.xcframework.zip"
let version = "0.99.53"
let checksum = "4576034afb570e0010a6d9df8294543146c123a1f7fde1aa893d002c9aaba960"

let package = Package(
    name: "Partout-Binary",
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
            url: "https://github.com/passepartoutvpn/partout/releases/download/\(version)/\(filename)",
            checksum: checksum
        ),
        .testTarget(
            name: "TargetTests",
            dependencies: ["Target"]
        )
    ]
)
