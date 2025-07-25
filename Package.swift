// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.152"
let checksum = "1d769a0adfbf6e9d46a7da62e7e0cab5268c0c2216a449523d73e44afabb5f1f"

// to download the core soruce
let coreSHA1 = "f26c0eeb5cb2ba6bd3fbf64fa090abcec492df9a"

// the global settings for C targets
let cSettings: [CSetting] = [
    .unsafeFlags([
        "-Wall", "-Wextra"//, "-Werror"
    ])
]
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
            targets: [
                "PartoutCoreWrapper",
                "PartoutProviders"
            ]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
        .package(url: "git@gitlab.com:passepartoutvpn/partout-core.git", revision: coreSHA1)
//        .package(path: "../partout-core")
    ],
    targets: [
//        .binaryTarget(
//            name: "PartoutCoreWrapper",
//            url: "https://github.com/passepartoutvpn/partout/releases/download/\(version)/\(binaryFilename)",
//            checksum: checksum
//        ),
        .target(
            name: "PartoutCoreWrapper",
            dependencies: [
                .product(name: "PartoutCore", package: "partout-core")
            ],
            path: "Sources/Core"
        ),
        .target(
            name: "PartoutProviders",
            dependencies: [
                .product(name: "PartoutCore", package: "partout-core")
            ],
            path: "Sources/Providers"
        ),
        .testTarget(
            name: "PartoutProvidersTests",
            dependencies: ["PartoutProviders"],
            path: "Tests/Providers",
            resources: [
                .process("Resources")
            ]
        )
    ]
)

//package.targets.append(contentsOf: [
//    .target(
//        name: "_PartoutCore_C",
//        path: "Sources/PartoutCore/_PartoutCore_C"
//    ),
//    .target(
//        name: "PartoutCore",
//        dependencies: ["_PartoutCore_C"],
//        path: "Sources/PartoutCore/PartoutCore"
//    )
//])
