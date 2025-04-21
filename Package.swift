// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// MARK: PartoutCore

enum Environment {
    case remoteBinary

    case remoteSource

    case localSource
}

let environment: Environment
environment = .remoteBinary
// environment = .remoteSource
// environment = .localSource

let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.91"
let checksum = "2543d3cd4ee630ecf421f9b2059e76f039b0bdec1bc319f38d346774b0885e0f"
let sha1 = "4762e0688760a47daad0f3e689363e7f4b337fa2"

// MARK: - Products

let applePlatforms: [Platform] = [.iOS, .macOS, .tvOS]
let nonApplePlatforms: [Platform] = [.android, .linux, .windows]

let package = Package(
    name: "partout",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "Partout",
            targets: ["Partout"]
        ),
        .library(
            name: "PartoutCoreWrapper",
            targets: ["PartoutCoreWrapper"]
        ),
        .library(
            name: "PartoutOpenVPN",
            targets: ["PartoutOpenVPN"]
        ),
        .library(
            name: "PartoutWireGuard",
            targets: ["PartoutWireGuard"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/iwill/generic-json-swift", from: "2.0.0"),
        .package(url: "https://github.com/passepartoutvpn/openssl-apple", from: "3.4.200"),
        .package(url: "https://github.com/passepartoutvpn/wireguard-apple", from: "1.1.2"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0")
    ]
)

// MARK: - Umbrella

package.targets.append(contentsOf: [
    .target(
        name: "Partout",
        dependencies: [
            "PartoutAPI",
            .target(name: "PartoutNE", condition: .when(platforms: applePlatforms)),
            .target(name: "_PartoutPlatformAndroid", condition: .when(platforms: [.android])),
            .target(name: "_PartoutPlatformApple", condition: .when(platforms: applePlatforms)),
            .target(name: "_PartoutPlatformWindows", condition: .when(platforms: [.windows]))
        ]
    ),
    .target(
        name: "PartoutAPI",
        dependencies: [
            .product(name: "GenericJSON", package: "generic-json-swift"),
            "PartoutCoreWrapper"
        ]
    ),
    .testTarget(
        name: "PartoutAPITests",
        dependencies: ["PartoutAPI"],
        resources: [
            .copy("Resources")
        ]
    ),
    .testTarget(
        name: "PartoutCoreTests",
        dependencies: ["PartoutCoreWrapper"]
    ),
    .testTarget(
        name: "PartoutTests",
        dependencies: ["Partout"],
        resources: [
            .copy("Resources")
        ]
    )
])

switch environment {
case .remoteBinary:
    package.targets.append(.binaryTarget(
        name: "PartoutCoreWrapper",
        url: "https://github.com/passepartoutvpn/partout/releases/download/\(version)/\(binaryFilename)",
        checksum: checksum
    ))
case .remoteSource:
    package.dependencies.append(
        .package(url: "git@github.com:passepartoutvpn/partout-core.git", revision: sha1)
    )
    package.targets.append(.target(
        name: "PartoutCoreWrapper",
        dependencies: [
            .product(name: "PartoutCore", package: "partout-core")
        ]
    ))
case .localSource:
    package.dependencies.append(
        .package(path: "../partout-core")
    )
    package.targets.append(.target(
        name: "PartoutCoreWrapper",
        dependencies: [
            .product(name: "PartoutCore", package: "partout-core")
        ]
    ))
}

// MARK: Platforms

package.targets.append(contentsOf: [
    .target(
        name: "PartoutNE",
        dependencies: [
            "PartoutCoreWrapper"
        ]
    ),
    .target(
        name: "_PartoutPlatformAndroid",
        dependencies: [
            "PartoutCoreWrapper"
        ]
    ),
    .target(
        name: "_PartoutPlatformApple",
        dependencies: [
            "PartoutCoreWrapper"
        ]
    ),
    .target(
        name: "_PartoutPlatformLinux",
        dependencies: [
            "PartoutCoreWrapper"
        ]
    ),
    .target(
        name: "_PartoutPlatformWindows",
        dependencies: [
            "PartoutCoreWrapper"
        ]
    ),
    .testTarget(
        name: "PartoutNETests",
        dependencies: ["PartoutNE"]
    ),
    .testTarget(
        name: "_PartoutPlatformAppleTests",
        dependencies: ["_PartoutPlatformApple"]
    )
])

// MARK: OpenVPN

package.targets.append(contentsOf: [
    .target(
        name: "PartoutOpenVPN",
        dependencies: ["_PartoutOpenVPNOpenSSL"]
    ),
    .target(
        name: "_PartoutCryptoOpenSSL_ObjC",
        dependencies: ["openssl-apple"]
    ),
    .target(
        name: "_PartoutOpenVPNOpenSSL_ObjC",
        dependencies: [
            "_PartoutCryptoOpenSSL_ObjC",
            "PartoutCoreWrapper"
        ],
        exclude: [
            "lib/COPYING",
            "lib/Makefile",
            "lib/README.LZO",
            "lib/testmini.c"
        ]
    ),
    .target(
        name: "_PartoutCryptoOpenSSL",
        dependencies: ["_PartoutCryptoOpenSSL_ObjC"]
    ),
    .target(
        name: "_PartoutOpenVPNOpenSSL",
        dependencies: [
            "_PartoutCryptoOpenSSL",
            "_PartoutOpenVPNOpenSSL_ObjC"
        ]
    ),
    .testTarget(
        name: "_PartoutCryptoOpenSSL_ObjCTests",
        dependencies: ["_PartoutCryptoOpenSSL"]
    ),
    .testTarget(
        name: "_PartoutOpenVPNOpenSSLTests",
        dependencies: ["_PartoutOpenVPNOpenSSL"],
        resources: [
            .process("Resources")
        ]
    )
])

// MARK: WireGuard

package.targets.append(contentsOf: [
    .target(
        name: "PartoutWireGuard",
        dependencies: ["_PartoutWireGuardGo"]
    ),
    .target(
        name: "_PartoutWireGuardGo",
        dependencies: [
            "PartoutCoreWrapper",
            .product(name: "WireGuardKit", package: "wireguard-apple")
        ],
        resources: [
            .process("Resources")
        ]
    ),
    .testTarget(
        name: "_PartoutWireGuardGoTests",
        dependencies: ["_PartoutWireGuardGo"]
    )
])
