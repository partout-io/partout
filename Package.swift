// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let environment: Environment
environment = .production
// environment = .localSource
// environment = .localBinary
// environment = .onlineBinary

// PartoutCore
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.81"
let checksum = "ae1222ccc1503b1835d67f6ea7f6f6778adcfd3a29f28024b1339f9573d2bd36"
let sha1 = "225c91e2d3c0637db5e06574820b487f8a4d41f8"

let applePlatforms: [Platform] = [.iOS, .macOS, .tvOS]
let nonApplePlatforms: [Platform] = [.android, .linux, .windows]

// MARK: Products

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
        name: "PartoutTests",
        dependencies: ["Partout"],
        resources: [
            .copy("Resources")
        ]
    )
])

// MARK: CoreWrapper

enum Environment {
    case production

    case localSource

    case localBinary

    case onlineBinary

    var dependencies: [Package.Dependency] {
        switch self {
        case .production:
            return [
                .package(url: "https://github.com/passepartoutvpn/partout-core", revision: sha1)
            ]
        case .localSource:
            return [
                .package(path: "CoreSource")
            ]
        case .localBinary, .onlineBinary:
            return []
        }
    }

    var coreTargetName: String {
        switch self {
        case .production, .localSource:
            return "PartoutCore"
        case .localBinary:
            return "PartoutCoreLocalBinary"
        case .onlineBinary:
            return "PartoutCoreOnlineBinary"
        }
    }

    var targets: [Target] {
        var targets: [Target] = []
        switch self {
        case .production:
            targets.append(.target(
                name: coreTargetName,
                dependencies: [
                    .product(name: "PartoutCoreSource", package: "partout-core")
                ]
            ))
        case .localSource:
            targets.append(.target(
                name: coreTargetName,
                dependencies: [
                    .product(name: "PartoutCoreSource", package: "CoreSource")
                ]
            ))
        case .localBinary:
            targets.append(.binaryTarget(
                name: coreTargetName,
                path: binaryFilename
            ))
        case .onlineBinary:
            targets.append(.binaryTarget(
                name: coreTargetName,
                url: "https://github.com/passepartoutvpn/partout/releases/download/\(version)/\(binaryFilename)",
                checksum: checksum
            ))
        }
        targets.append(.target(
            name: "PartoutCoreWrapper",
            dependencies: [.byName(name: coreTargetName)]
        ))
        targets.append(.testTarget(
            name: "PartoutCoreWrapperTests",
            dependencies: ["PartoutCoreWrapper"]
        ))
        return targets
    }
}

package.dependencies.append(contentsOf: environment.dependencies)
package.targets.append(contentsOf: environment.targets)

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
