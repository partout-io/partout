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
            url: "https://github.com/passepartoutvpn/passepartoutkit/releases/download/0.99.8/PassepartoutKit.xcframework.zip",
            checksum: "dd15564960aa4b30500cee5510d76c4361711e9a61e06ba0022f22e1ec9adcaf"
        ),
        .testTarget(
            name: "TargetTests",
            dependencies: ["Target"]
        )
    ]
)
