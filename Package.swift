// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Partout",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "Partout",
            targets: ["_Partout"]
        ),
        .library(
            name: "PartoutNetworking",
            targets: ["_PartoutNetworking"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
        .package(path: "Plugins/PartoutOpenVPNOpenSSL"),
        .package(path: "Plugins/PartoutSupport"),
        .package(path: "Plugins/PartoutWireGuardGo")
    ],
    targets: [
        .target(
            name: "_Partout",
            dependencies: [
                "PartoutSupport"
            ]
        ),
        .target(
            name: "_PartoutNetworking",
            dependencies: [
                "PartoutOpenVPNOpenSSL",
                "PartoutWireGuardGo"
            ]
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: ["_Partout"]
        )
    ]
)
