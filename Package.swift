// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let filename = "Partout.xcframework.zip"
let version = "0.99.51"
let checksum = "9b898fadb3204b185f5929e8e176fe75a1e447a47b9e966556cacb6f001add0a"

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
            url: "https://github.com/passepartoutvpn/passepartout/releases/download/\(version)/\(filename)",
            checksum: checksum
        ),
        .testTarget(
            name: "TargetTests",
            dependencies: ["Target"]
        )
    ]
)
