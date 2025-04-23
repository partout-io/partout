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
//environment = .localSource

// for action-release-binary-package
let sha1 = "2d5fb2ef1cf07e557cfe541638469b2263323694"
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.100"
let checksum = "955651e7692023cffaafc52ea04f6513e8f6b40e70dff5a79b80bf3a6586230b"

let applePlatforms: [Platform] = [.iOS, .macOS, .tvOS]
let nonApplePlatforms: [Platform] = [.android, .linux, .windows]

// MARK: - Products

enum Area: CaseIterable {
    case api

    case documentation

    case openvpn

    case wireguard
}

let areas: Set<Area> = []//Set(Area.allCases)

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
            name: "PartoutProviders",
            targets: ["PartoutProviders"]
        )
    ]
)

package.targets.append(contentsOf: [
    {
        var dependencies: [Target.Dependency] = [
            .target(name: "PartoutProviders"),
            .target(name: "_PartoutPlatformAndroid", condition: .when(platforms: [.android])),
            .target(name: "_PartoutPlatformApple", condition: .when(platforms: applePlatforms)),
            .target(name: "_PartoutPlatformAppleNE", condition: .when(platforms: applePlatforms)),
            .target(name: "_PartoutPlatformLinux", condition: .when(platforms: [.linux])),
            .target(name: "_PartoutPlatformWindows", condition: .when(platforms: [.windows]))
        ]
        if areas.contains(.api) {
            dependencies.append("PartoutAPI")
        }
        if areas.contains(.openvpn) {
            dependencies.append("_PartoutOpenVPN")
        }
        if areas.contains(.wireguard) {
            dependencies.append("_PartoutWireGuard")
        }
        return .target(
            name: "Partout",
            dependencies: dependencies,
            path: "Sources/Partout"
        )
    }(),
    .testTarget(
        name: "PartoutTests",
        dependencies: ["Partout"],
        path: "Tests/Partout",
        resources: [
            .copy("Resources")
        ]
    )
])

if areas.contains(.documentation) {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0")
    )
}

// MARK: Core

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
        ],
        path: "Sources/Core"
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
        path: "Sources/Core"
    ))
}

package.targets.append(
    .testTarget(
        name: "PartoutCoreTests",
        dependencies: ["PartoutCoreWrapper"],
        path: "Tests/Core"
    )
)

// MARK: Platforms

package.targets.append(contentsOf: [
    .target(
        name: "_PartoutPlatformAndroid",
        dependencies: ["PartoutCoreWrapper"],
        path: "Sources/Platforms/Android"
    ),
    .target(
        name: "_PartoutPlatformApple",
        dependencies: ["PartoutCoreWrapper"],
        path: "Sources/Platforms/Apple"
    ),
    .target(
        name: "_PartoutPlatformAppleNE",
        dependencies: ["PartoutCoreWrapper"],
        path: "Sources/Platforms/AppleNE"
    ),
    .target(
        name: "_PartoutPlatformLinux",
        dependencies: ["PartoutCoreWrapper"],
        path: "Sources/Platforms/Linux"
    ),
    .target(
        name: "_PartoutPlatformWindows",
        dependencies: ["PartoutCoreWrapper"],
        path: "Sources/Platforms/Windows"
    ),
    .testTarget(
        name: "_PartoutPlatformAppleNETests",
        dependencies: ["_PartoutPlatformAppleNE"],
        path: "Tests/Platforms/AppleNE"
    ),
    .testTarget(
        name: "_PartoutPlatformAppleTests",
        dependencies: ["_PartoutPlatformApple"],
        path: "Tests/Platforms/Apple"
    )
])

// MARK: Providers

package.targets.append(contentsOf: [
    .target(
        name: "PartoutProviders",
        dependencies: ["PartoutCoreWrapper"],
        path: "Sources/Providers"
    ),
    .testTarget(
        name: "PartoutProvidersTests",
        dependencies: ["PartoutProviders"],
        path: "Tests/Providers"
    )
])

// MARK: - API

if areas.contains(.api) {
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
        .testTarget(
            name: "PartoutAPITests",
            dependencies: ["PartoutAPI"],
            path: "Tests/API",
            resources: [
                .copy("Resources")
            ]
        )
    ])
}

// MARK: OpenVPN

if areas.contains(.openvpn) {
    package.dependencies.append(contentsOf: [
        .package(url: "https://github.com/passepartoutvpn/openssl-apple", from: "3.4.200")
    ])
    package.products.append(contentsOf: [
        .library(
            name: "PartoutOpenVPN",
            targets: ["PartoutOpenVPNWrapper"]
        )
    ])
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutOpenVPNWrapper",
            dependencies: ["_PartoutOpenVPNOpenSSL"],
            path: "Sources/OpenVPN/Wrapper"
        ),
        .target(
            name: "_PartoutCryptoOpenSSL",
            dependencies: ["_PartoutCryptoOpenSSL_ObjC"],
            path: "Sources/OpenVPN/CryptoOpenSSL"
        ),
        .target(
            name: "_PartoutCryptoOpenSSL_ObjC",
            dependencies: ["openssl-apple"],
            path: "Sources/OpenVPN/CryptoOpenSSL_ObjC"
        ),
        .target(
            name: "_PartoutOpenVPN",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/OpenVPN/Base"
        ),
        .target(
            name: "_PartoutOpenVPNOpenSSL",
            dependencies: [
                "_PartoutCryptoOpenSSL",
                "_PartoutOpenVPN",
                "_PartoutOpenVPNOpenSSL_ObjC"
            ],
            path: "Sources/OpenVPN/OpenVPNOpenSSL"
        ),
        .target(
            name: "_PartoutOpenVPNOpenSSL_ObjC",
            dependencies: ["_PartoutCryptoOpenSSL_ObjC"],
            path: "Sources/OpenVPN/OpenVPNOpenSSL_ObjC",
            exclude: [
                "lib/COPYING",
                "lib/Makefile",
                "lib/README.LZO",
                "lib/testmini.c"
            ]
        ),
        .testTarget(
            name: "_PartoutCryptoOpenSSL_ObjCTests",
            dependencies: ["_PartoutCryptoOpenSSL"],
            path: "Tests/OpenVPN/CryptoOpenSSL_ObjC"
        ),
        .testTarget(
            name: "_PartoutOpenVPNTests",
            dependencies: ["_PartoutOpenVPN"],
            path: "Tests/OpenVPN/Base"
        ),
        .testTarget(
            name: "_PartoutOpenVPNOpenSSLTests",
            dependencies: ["_PartoutOpenVPNOpenSSL"],
            path: "Tests/OpenVPN/OpenVPNOpenSSL",
            resources: [
                .process("Resources")
            ]
        )
    ])
}

// MARK: WireGuard

if areas.contains(.wireguard) {
    package.dependencies.append(contentsOf: [
        .package(url: "https://github.com/passepartoutvpn/wireguard-apple", from: "1.1.2")
    ])
    package.products.append(contentsOf: [
        .library(
            name: "PartoutWireGuard",
            targets: ["PartoutWireGuardWrapper"]
        )
    ])
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutWireGuardWrapper",
            dependencies: ["_PartoutWireGuardGo"],
            path: "Sources/WireGuard/Wrapper"
        ),
        .target(
            name: "_PartoutWireGuard",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/WireGuard/Base"
        ),
        .target(
            name: "_PartoutWireGuardGo",
            dependencies: [
                "_PartoutWireGuard",
                .product(name: "WireGuardKit", package: "wireguard-apple")
            ],
            path: "Sources/WireGuard/WireGuardGo",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "_PartoutWireGuardTests",
            dependencies: ["_PartoutWireGuard"],
            path: "Tests/WireGuard/Base"
        ),
        .testTarget(
            name: "_PartoutWireGuardGoTests",
            dependencies: ["_PartoutWireGuardGo"],
            path: "Tests/WireGuard/WireGuardGo"
        )
    ])
}
