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
            url: "https://github.com/passepartoutvpn/passepartoutkit/releases/download/0.99.7/PassepartoutKit.xcframework.zip",
            checksum: "f28fa062214a31681caa780070f9a2110b86bcd15adc069afb6a728cad2300ad"
        ),
        .testTarget(
            name: "TargetTests",
            dependencies: ["Target"]
        )
    ]
)
