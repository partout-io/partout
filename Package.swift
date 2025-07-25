// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

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
                "PartoutCore",
                "PartoutProviders"
            ]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "PartoutProviders",
            dependencies: ["PartoutCore"],
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

package.targets.append(contentsOf: [
    .target(
        name: "_PartoutCore_C",
        path: "Sources/PartoutCore/_PartoutCore_C"
    ),
    .target(
        name: "PartoutCore",
        dependencies: ["_PartoutCore_C"],
        path: "Sources/PartoutCore/PartoutCore"
    )
])
