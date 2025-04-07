// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ExternalDependencies",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "ExternalDependencies",
            targets: ["ExternalDependencies"]
        )
    ],
    dependencies: [
        .package(path: "../../Passepartout/Packages/Partout-Framework"),
        .package(path: "../../Passepartout/Packages/PartoutOpenVPNOpenSSL"),
        .package(path: "../../Passepartout/Packages/PartoutWireGuardGo")
    ],
    targets: [
        .target(
            name: "ExternalDependencies",
            dependencies: [
                "Partout-Framework",
                "PartoutOpenVPNOpenSSL",
                "PartoutWireGuardGo"
            ]
        ),
        .testTarget(
            name: "ExternalDependenciesTests",
            dependencies: ["ExternalDependencies"]
        )
    ]
)
