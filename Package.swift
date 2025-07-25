// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// MARK: Tuning

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.152"
let checksum = "1d769a0adfbf6e9d46a7da62e7e0cab5268c0c2216a449523d73e44afabb5f1f"

// to download the core soruce
let coreSHA1 = "f26c0eeb5cb2ba6bd3fbf64fa090abcec492df9a"

// deployment environment
let environment: Environment = .documentation

// the global settings for C targets
let cSettings: [CSetting] = [
    .unsafeFlags([
        "-Wall", "-Wextra"//, "-Werror"
    ])
]

// MARK: Package

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
                environment.coreDependency,
                "PartoutAPI",
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
            dependencies: [
                .target(name: environment.coreDependency)
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

// MARK: API

package.products.append(
    .library(
        name: "PartoutAPI",
        targets: ["PartoutAPI"]
    )
)
package.dependencies.append(
    .package(url: "https://github.com/iwill/generic-json-swift", from: "2.0.0")
)
package.targets.append(contentsOf: [
    .target(
        name: "PartoutAPI",
        dependencies: [
            .product(name: "GenericJSON", package: "generic-json-swift"),
            "PartoutProviders"
        ],
        path: "Sources/API"
    ),
    .target(
        name: "PartoutAPIBundle",
        dependencies: [
            "PartoutAPI",
            "PartoutProviders"
        ],
        path: "Sources/APIBundle",
        resources: [
            .copy("JSON")
        ]
    ),
    .testTarget(
        name: "PartoutAPITests",
        dependencies: ["PartoutAPI"],
        path: "Tests/API"
    )
])

// MARK: Core

enum Environment {
    case remoteBinary
    case remoteSource
    case localBinary
    case localSource
    case documentation

    var coreDependency: String {
        switch self {
        case .documentation: "PartoutCore"
        default: "PartoutCoreWrapper"
        }
    }
}

switch environment {
case .remoteBinary:
    package.targets.append(.binaryTarget(
        name: "PartoutCoreWrapper",
        url: "https://github.com/passepartoutvpn/partout/releases/download/\(version)/\(binaryFilename)",
        checksum: checksum
    ))
case .remoteSource:
    package.dependencies.append(
//        .package(url: "git@github.com:passepartoutvpn/partout-core.git", revision: coreSHA1)
        .package(url: "git@gitlab.com:passepartoutvpn/partout-core.git", revision: coreSHA1)
    )
    package.targets.append(.target(
        name: "PartoutCoreWrapper",
        dependencies: [
            .product(name: "PartoutCore", package: "partout-core")
        ],
        path: "Sources/Core"
    ))
case .localBinary:
    package.targets.append(.binaryTarget(
        name: "PartoutCoreWrapper",
        path: "../partout-core/PartoutCore.xcframework"
    ))
case .localSource:
    package.dependencies.append(
        .package(path: "../partout-core")
    )
    package.targets.append(.target(
        name: "PartoutCoreWrapper",
        dependencies: [
            .product(name: "PartoutCore", package: "partout-core")
        ],
        path: "../partout-core/Sources/PartoutCore"
    ))
case .documentation:
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutCore_C",
            path: "PartoutCore/_PartoutCore_C"
        ),
        .target(
            name: "PartoutCore",
            dependencies: ["_PartoutCore_C"],
            path: "PartoutCore/PartoutCore"
        )
    ])
}
if environment != .documentation {
    package.targets.append(contentsOf: [
        .testTarget(
            name: "PartoutCoreTests",
            dependencies: ["PartoutCoreWrapper"],
            path: "Tests/Core"
        )
    ])
}
