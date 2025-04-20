// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Partout",
    defaultLocalization: "en",
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
            name: "PartoutOpenVPN",
            targets: ["PartoutOpenVPN"]
        ),
        .library(
            name: "PartoutWireGuard",
            targets: ["PartoutWireGuard"]
        )
    ],
    dependencies: [
        .package(path: "Core"),
        .package(url: "https://github.com/iwill/generic-json-swift", from: "2.0.0"),
        .package(url: "https://github.com/passepartoutvpn/openssl-apple", from: "3.4.200"),
        .package(url: "https://github.com/passepartoutvpn/wireguard-apple", from: "1.1.2"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "_Partout",
            dependencies: [
                "PartoutSupport"
            ]
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: ["_Partout"]
        )
    ]
)

// MARK: Support

let applePlatforms: [Platform] = [.iOS, .macOS, .tvOS]
let nonApplePlatforms: [Platform] = [.android, .linux, .windows]

package.targets.append(contentsOf: [
    .target(
        name: "PartoutAPI",
        dependencies: [
            .product(name: "GenericJSON", package: "generic-json-swift"),
            .product(name: "PartoutCore", package: "Core")
        ]
    ),
    .target(
        name: "PartoutNE",
        dependencies: [
            .product(name: "PartoutCore", package: "Core")
        ]
    ),
    .target(
        name: "_PartoutPlatformAndroid",
        dependencies: [
            .product(name: "PartoutCore", package: "Core")
        ]
    ),
    .target(
        name: "_PartoutPlatformApple",
        dependencies: [
            .product(name: "PartoutCore", package: "Core")
        ]
    ),
    .target(
        name: "_PartoutPlatformWindows",
        dependencies: [
            .product(name: "PartoutCore", package: "Core")
        ]
    ),
    .target(
        name: "PartoutSupport",
        dependencies: [
            "PartoutAPI",
            .target(name: "PartoutNE", condition: .when(platforms: applePlatforms)),
            .target(name: "_PartoutPlatformAndroid", condition: .when(platforms: [.android])),
            .target(name: "_PartoutPlatformApple", condition: .when(platforms: applePlatforms)),
            .target(name: "_PartoutPlatformWindows", condition: .when(platforms: [.windows]))
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
        name: "PartoutNETests",
        dependencies: ["PartoutNE"]
    ),
    .testTarget(
        name: "PartoutPlatformAppleTests",
        dependencies: ["_PartoutPlatformApple"]
    ),
    .testTarget(
        name: "PartoutSupportTests",
        dependencies: ["PartoutSupport"],
        resources: [
            .copy("Resources")
        ]
    )
])

// MARK: OpenVPN

package.targets.append(contentsOf: [
    .target(
        name: "PartoutOpenVPN",
        dependencies: ["PartoutOpenVPNOpenSSL"]
    ),
    .target(
        name: "CPartoutCryptoOpenSSL",
        dependencies: ["openssl-apple"]
    ),
    .target(
        name: "CPartoutOpenVPNOpenSSL",
        dependencies: [
            "CPartoutCryptoOpenSSL",
            .product(name: "PartoutCore", package: "Core")
        ],
        exclude: [
            "lib/COPYING",
            "lib/Makefile",
            "lib/README.LZO",
            "lib/testmini.c"
        ]
    ),
    .target(
        name: "PartoutCryptoOpenSSL",
        dependencies: ["CPartoutCryptoOpenSSL"]
    ),
    .target(
        name: "PartoutOpenVPNOpenSSL",
        dependencies: [
            "CPartoutOpenVPNOpenSSL",
            "PartoutCryptoOpenSSL"
        ]
    ),
    .testTarget(
        name: "CPartoutCryptoOpenSSLTests",
        dependencies: ["PartoutCryptoOpenSSL"]
    ),
    .testTarget(
        name: "PartoutOpenVPNOpenSSLTests",
        dependencies: ["PartoutOpenVPNOpenSSL"],
        resources: [
            .process("Resources")
        ]
    )
])

// MARK: WireGuard

package.targets.append(contentsOf: [
    .target(
        name: "PartoutWireGuard",
        dependencies: ["PartoutWireGuardGo"]
    ),
    .target(
        name: "PartoutWireGuardGo",
        dependencies: [
            .product(name: "PartoutCore", package: "Core"),
            .product(name: "WireGuardKit", package: "wireguard-apple")
        ],
        resources: [
            .process("Resources")
        ]
    ),
    .testTarget(
        name: "PartoutWireGuardGoTests",
        dependencies: ["PartoutWireGuardGo"]
    )
])
