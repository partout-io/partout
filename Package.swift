// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let filename = "PassepartoutKit.xcframework.zip"
let version = "0.99.22"
let checksum = "ff44cd0ab1b33670c85dafff7d4e92657edfffab9bf46d3d8289c83de1670013"

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
            url: "https://github.com/passepartoutvpn/passepartoutkit/releases/download/\(version)/\(filename)",
            checksum: checksum
        ),
        .testTarget(
            name: "TargetTests",
            dependencies: ["Target"]
        )
    ]
)
