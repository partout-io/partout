// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// MARK: Tuning

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.130"
let checksum = "11afaadc343e0646be9d50ad7b2d6069ecd78105cb297d5daa036eb1207e1022"

// to download the core soruce
let coreSHA1 = "bfac7b7f2831fa0b030e5972864e93754d825c74"

// deployment environment
let environment: Environment = .remoteBinary

// implies included targets (exclude docs until ready)
let areas = {
    var included = Set(Area.allCases)
    included.remove(.documentation) // until ready
#if os(Windows) || os(Linux)
    included.remove(.wireguard)
#endif
    return included
}()

// external packages
let vendors: [Vendor]
#if os(Windows)
vendors = [.windowsCNG]
#elseif os(Linux)
vendors = [.openSSLShared]
#else
vendors = [.apple, .openSSLApple, .wgAppleGo]
#endif

// the global settings for C targets
let cSettings: [CSetting] = [
    .unsafeFlags([
        "-Wall", "-Wextra"//, "-Werror"
    ])
]

// MARK: - Structures

enum Environment {
    case remoteBinary

    case remoteSource

    case localBinary

    case localSource
}

enum Area: CaseIterable {
    case api

    case documentation

    case openvpn

    case wireguard

    var requirements: Set<Feature> {
        switch self {
        case .openvpn:
            return [.crypto, .tls]
        case .wireguard:
            return [.wgBackend]
        default:
            return []
        }
    }
}

enum Feature {
    case crypto

    case tls

    case wgBackend
}

enum Vendor: CaseIterable {
    case apple

    // TODO: ###, crypto/TLS on Apple
    case appleCrypto

    case openSSLApple

    case openSSLShared

    case wgAppleGo

    // TODO: ###, WireGuard on Linux
    case wgLinuxKernel

    // TODO: ###, WireGuard on Windows
    case wgWindowsNT

    // TODO: ###, crypto/TLS on Windows
    case windowsCNG

    var target: Target.Dependency? {
        switch self {
        case .apple:
            return "_PartoutVendorsApple"
        case .openSSLApple:
            return "openssl-apple"
        case .openSSLShared:
            return "_PartoutVendorsOpenSSL"
        case .wgAppleGo:
            return "wg-go-apple"
        default:
            return nil
        }
    }

    var features: Set<Feature> {
        switch self {
        case .appleCrypto, .openSSLApple, .openSSLShared, .windowsCNG:
            return [.crypto, .tls]
        case .wgAppleGo, .wgLinuxKernel, .wgWindowsNT:
            return [.wgBackend]
        default:
            return []
        }
    }
}

extension Collection where Element == Vendor {
    func firstSupporting(_ feature: Feature) -> Vendor? {
        vendors.first {
            $0.features.contains(feature)
        }
    }
}

// MARK: - Package

let package = Package(
    name: "partout",
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
            name: "PartoutCryptoCore",
            targets: ["_PartoutCryptoCore"]
        ),
        .library(
            name: "PartoutVendorsPortable",
            targets: ["_PartoutVendorsPortable"]
        )
    ]
)

package.targets.append(contentsOf: [
    .target(
        name: "Partout",
        dependencies: {
            var dependencies: [Target.Dependency] = ["PartoutProviders"]
            if vendors.contains(.apple) {
                dependencies.append("_PartoutVendorsApple")
            }
            if areas.contains(.api) {
                dependencies.append("PartoutAPI")
            }
            if areas.contains(.openvpn) {
                dependencies.append("_PartoutOpenVPNCore")
            }
            if areas.contains(.wireguard) {
                dependencies.append("_PartoutWireGuardCore")
            }
            return dependencies
        }(),
        path: "Sources/Partout"
    ),
    .testTarget(
        name: "PartoutTests",
        dependencies: ["Partout"],
        path: "Tests/Partout",
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
        .package(url: "git@github.com:passepartoutvpn/partout-core.git", revision: coreSHA1)
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
        path: "Sources/Core"
    ))
}
package.targets.append(contentsOf: [
    .testTarget(
        name: "PartoutCoreTests",
        dependencies: ["PartoutCoreWrapper"],
        path: "Tests/Core"
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

// MARK: Documentation

if areas.contains(.documentation) {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0")
    )
}

// MARK: - Vendors

package.targets.append(contentsOf: [
    .target(
        name: "_PartoutVendorsPortable",
        dependencies: [
            "_PartoutCryptoCore",
            "_PartoutVendorsPortable_C",
            "PartoutCoreWrapper"
        ],
        path: "Sources/Vendors/Portable"
    ),
    .target(
        name: "_PartoutVendorsPortable_C",
        path: "Sources/Vendors/Portable_C"
    )
])

vendors.forEach {
    switch $0 {
    case .apple:
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutVendorsApple",
                dependencies: ["_PartoutVendorsAppleNE"],
                path: "Sources/Vendors/Apple"
            ),
            .target(
                name: "_PartoutVendorsAppleNE",
                dependencies: ["_PartoutVendorsPortable"],
                path: "Sources/Vendors/AppleNE"
            ),
            .testTarget(
                name: "_PartoutVendorsAppleNETests",
                dependencies: ["_PartoutVendorsAppleNE"],
                path: "Tests/Vendors/AppleNE"
            ),
            .testTarget(
                name: "_PartoutVendorsAppleTests",
                dependencies: ["_PartoutVendorsApple"],
                path: "Tests/Vendors/Apple"
            )
        ])

    case .openSSLApple, .openSSLShared:
        guard let openSSLTarget = $0.target else {
            fatalError("OpenSSL does not provide any target")
        }

        // system shared
        if $0 == .openSSLShared {
            package.targets.append(contentsOf: [
                .systemLibrary(
                    name: "_PartoutVendorsOpenSSL",
                    path: "Sources/Vendors/OpenSSL",
                    pkgConfig: "openssl",
                    providers: [
                        .apt(["libssl-dev"])
                    ]
                )
            ])
        }

        // new (C)
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutCryptoOpenSSL_C",
                dependencies: [
                    "_PartoutCryptoCore",
                    openSSLTarget
                ],
                path: "Sources/Crypto/OpenSSL_C"
            ),
            .testTarget(
                name: "_PartoutCryptoOpenSSL_CTests",
                dependencies: ["_PartoutCryptoOpenSSL_C"],
                path: "Tests/Crypto/OpenSSL_C",
                exclude: [
                    "CryptoPerformanceTests.swift"
                ]
            )
        ])

        // legacy (ObjC)
        if $0 == .openSSLApple {
            package.dependencies.append(.package(url: "https://github.com/passepartoutvpn/openssl-apple", from: "3.5.101"))

            package.targets.append(contentsOf: [
                .target(
                    name: "PartoutCryptoOpenSSL_ObjC",
                    dependencies: [openSSLTarget],
                    path: "Sources/Crypto/OpenSSL_ObjC"
                ),
                .testTarget(
                    name: "PartoutCryptoOpenSSL_ObjCTests",
                    dependencies: ["PartoutCryptoOpenSSL_ObjC"],
                    path: "Tests/Crypto/OpenSSL_ObjC"
                )
            ])
        }

    case .wgAppleGo:
        package.dependencies.append(.package(url: "https://github.com/passepartoutvpn/wg-go-apple", from: "0.0.20250630"))

    default:
        break
    }
}

// MARK: Crypto

package.targets.append(contentsOf: [
    .target(
        name: "_PartoutCryptoCore",
        dependencies: ["_PartoutCryptoCore_C"],
        path: "Sources/Crypto/Core"
    ),
    .target(
        name: "_PartoutCryptoCore_C",
        path: "Sources/Crypto/Core_C"
    ),
    .testTarget(
        name: "_PartoutCryptoCoreTests",
        dependencies: ["_PartoutCryptoCore"],
        path: "Tests/Crypto/Core"
    )
])

// MARK: - OpenVPN

if areas.contains(.openvpn) {
    let mainTarget: String
#if os(Windows) || os(Linux)
    mainTarget = "_PartoutOpenVPN_Cross"
#else
    mainTarget = "_PartoutOpenVPNOpenSSL"
#endif

    package.products.append(contentsOf: [
        .library(
            name: "PartoutOpenVPN",
            targets: ["PartoutOpenVPN"]
        ),
        .library(
            name: "_PartoutOpenVPNCore",
            targets: ["_PartoutOpenVPNCore"]
        )
    ])
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutOpenVPN",
            dependencies: [mainTarget.asTargetDependency],
            path: "Sources/OpenVPN/Wrapper"
        ),
        .target(
            name: "_PartoutOpenVPNCore",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/OpenVPN/Core"
        ),
        .testTarget(
            name: "_PartoutOpenVPNTests",
            dependencies: ["_PartoutOpenVPNCore"],
            path: "Tests/OpenVPN/Core"
        )
    ])

#if !os(Windows) && !os(Linux)
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOpenVPNOpenSSL",
            dependencies: [
                "_PartoutOpenVPNCore",
                "_PartoutOpenVPN_Cross",
                "_PartoutOpenVPNOpenSSL_ObjC"
            ],
            path: "Sources/OpenVPN/OpenVPNOpenSSL"
        ),
        .target(
            name: "_PartoutOpenVPNOpenSSL_ObjC",
            dependencies: ["PartoutCryptoOpenSSL_ObjC"],
            path: "Sources/OpenVPN/OpenVPNOpenSSL_ObjC",
            exclude: [
                "lib/COPYING",
                "lib/Makefile",
                "lib/README.LZO",
                "lib/testmini.c"
            ]
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
#endif

    // cross-platform (experimental)
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOpenVPN_C",
            // FIXME: ###, pick by vendor (.crypto + .tls => .openvpn)
            dependencies: ["_PartoutCryptoOpenSSL_C"],
            path: "Sources/OpenVPN/OpenVPN_C"
        ),
        .target(
            name: "_PartoutOpenVPN_Cross",
            dependencies: [
                "_PartoutOpenVPNCore",
                "_PartoutOpenVPN_C",
                "_PartoutVendorsPortable"
            ],
            path: "Sources/OpenVPN/OpenVPN_Cross",
            exclude: {
                var list: [String] = ["Internal/Legacy"]
#if !os(Windows) && !os(Linux)
                list.append("StandardOpenVPNParser+Default.swift")
#endif
                return list
            }(),
            swiftSettings: [
                .define("OPENVPN_WRAPPED_NATIVE")
            ]
        ),
        .testTarget(
            name: "_PartoutOpenVPN_CrossTests",
            dependencies: ["_PartoutOpenVPN_Cross"],
            path: "Tests/OpenVPN/OpenVPN_Cross",
            exclude: [
                "DataPathPerformanceTests.swift"
            ],
            resources: [
                .process("Resources")
            ]
        )
    ])
}

// MARK: WireGuard

if areas.contains(.wireguard) {
    guard let backendTarget = vendors.firstSupporting(.wgBackend)?.target else {
        fatalError("WireGuard requires 3rd-party backend")
    }

    package.products.append(contentsOf: [
        .library(
            name: "PartoutWireGuard",
            targets: ["PartoutWireGuard"]
        ),
        .library(
            name: "_PartoutWireGuardCore",
            targets: ["_PartoutWireGuardCore"]
        )
    ])
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutWireGuard",
            dependencies: ["_PartoutWireGuardGo"],
            path: "Sources/WireGuard/Wrapper"
        ),
        .target(
            name: "_PartoutWireGuardCore",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/WireGuard/Core"
        ),
        .target(
            name: "_PartoutWireGuardC",
            path: "Sources/WireGuard/WireGuardC",
            publicHeadersPath: "."
        ),
        .target(
            name: "_PartoutWireGuardGo",
            dependencies: [
                "_PartoutWireGuardC",
                "_PartoutWireGuardCore",
                backendTarget
            ],
            path: "Sources/WireGuard/WireGuardGo",
        ),
        .testTarget(
            name: "_PartoutWireGuardTests",
            dependencies: ["_PartoutWireGuardCore"],
            path: "Tests/WireGuard/Core"
        ),
        .testTarget(
            name: "_PartoutWireGuardGoTests",
            dependencies: ["_PartoutWireGuardGo"],
            path: "Tests/WireGuard/WireGuardGo"
        )
    ])
}

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
            path: "Tests/API"
        )
    ])
}

// MARK: -

private extension String {
    var asTargetDependency: Target.Dependency {
        .target(name: self)
    }

    var asProductDependency: Target.Dependency {
        .product(name: self, package: self)
    }
}
