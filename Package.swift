// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// MARK: Package

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.152"
let checksum = "1d769a0adfbf6e9d46a7da62e7e0cab5268c0c2216a449523d73e44afabb5f1f"

// to download the core soruce
let coreSHA1 = "f26c0eeb5cb2ba6bd3fbf64fa090abcec492df9a"

// deployment environment
let environment: Environment = .localSource
let areas: Set<Area> = Area.default

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
                environment.coreDependency,
                "PartoutAPI",
                "PartoutProviders",
                "_PartoutVendorsCrypto_C",
                "_PartoutVendorsPortable"
            ]
        )
    ],
)

if areas.contains(.documentation) {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0")
    )
}

// MARK: - Providers

package.targets.append(contentsOf: [
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
])

// MARK: API

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
}

// MARK: - OpenVPN

if areas.contains(.openVPN) {
    let mainTarget: String
    switch OS.current {
    case .android, .linux, .windows:
        mainTarget = "_PartoutOpenVPN_Cross"
    default:
        mainTarget = "_PartoutOpenVPNOpenSSL" // legacy
    }

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
            dependencies: [
                .target(name: mainTarget)
            ],
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

    // legacy
    if OS.current == .apple {
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
                name: "_PartoutCryptoOpenSSL_ObjC",
                dependencies: ["openssl-apple"],
                path: "Sources/Vendors/Crypto/CryptoOpenSSL_ObjC"
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
                name: "_PartoutOpenVPNOpenSSLTests",
                dependencies: ["_PartoutOpenVPNOpenSSL"],
                path: "Tests/OpenVPN/OpenVPNOpenSSL",
                resources: [
                    .process("Resources")
                ]
            )
        ])
    }

    // cross-platform (experimental)
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOpenVPN_C",
            dependencies: ["_PartoutVendorsCrypto_C"],
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
                if OS.current == .apple {
                    list.append("StandardOpenVPNParser+Default.swift")
                }
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

if areas.contains(.wireGuard) {
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
            dependencies: ["_PartoutWireGuard_Cross"],
            path: "Sources/WireGuard/Wrapper"
        ),
        .target(
            name: "_PartoutWireGuardCore",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/WireGuard/Core"
        ),
        .target(
            name: "_PartoutWireGuard_C",
            path: "Sources/WireGuard/WireGuard_C",
            publicHeadersPath: "."
        ),
        .target(
            name: "_PartoutWireGuard_Cross",
            dependencies: [
                "_PartoutVendorsWireGuardBackend",
                "_PartoutWireGuard_C",
                "_PartoutWireGuardCore"
            ],
            path: "Sources/WireGuard/WireGuard_Cross",
        ),
        .testTarget(
            name: "_PartoutWireGuardTests",
            dependencies: ["_PartoutWireGuardCore"],
            path: "Tests/WireGuard/Core"
        ),
        .testTarget(
            name: "_PartoutWireGuard_CrossTests",
            dependencies: ["_PartoutWireGuard_Cross"],
            path: "Tests/WireGuard/WireGuard_Cross"
        )
    ])
}

// MARK: - Vendors

package.targets.append(contentsOf: [
    .target(
        name: "_PartoutVendorsCryptoCore_C",
        dependencies: ["_PartoutVendorsPortable_C"],
        path: "Sources/Vendors/Crypto/CryptoCore_C"
    ),
    .target(
        name: "_PartoutVendorsPortable",
        dependencies: [
            .target(name: environment.coreDependency),
            "_PartoutVendorsPortable_C"
        ],
        path: "Sources/Vendors/Portable"
    ),
    .target(
        name: "_PartoutVendorsPortable_C",
        path: "Sources/Vendors/Portable_C"
    ),
    .target(
        name: "_PartoutVendorsWireGuardBackendCore",
        path: "Sources/Vendors/WireGuard/BackendCore"
    ),
    .testTarget(
        name: "_PartoutVendorsPortableTests",
        dependencies: ["_PartoutVendorsPortable"],
        path: "Tests/Vendors/Portable"
    )
])

// pick implementation
switch OS.current {
case .apple:
    package.dependencies.append(
        .package(url: "https://github.com/passepartoutvpn/openssl-apple", exact: "3.5.200")
    )
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutVendorsCryptoImpl",
            dependencies: ["openssl-apple"],
            path: "Sources/Vendors/Crypto/OpenSSL",
            exclude: [
                "include/shim.h",
                "module.modulemap"
            ]
        ),
        .target(
            name: "_PartoutVendorsCrypto_C",
            dependencies: [
                "_PartoutVendorsCryptoCore_C",
                "_PartoutVendorsCryptoImpl"
            ],
            path: "Sources/Vendors/Crypto/CryptoOpenSSL_C"
        )
    ])
    if areas.contains(.wireGuard) {
        package.dependencies.append(
            .package(url: "https://github.com/passepartoutvpn/wg-go-apple", from: "0.0.20250630")
        )
        package.targets.append(
            .target(
                name: "_PartoutVendorsWireGuardBackend",
                dependencies: [
                    "_PartoutVendorsWireGuardBackendCore",
                    "wg-go-apple"
                ],
                path: "Sources/Vendors/WireGuard/BackendGo"
            )
        )
    }
case .linux:
    package.targets.append(contentsOf: [
        .systemLibrary(
            name: "_PartoutVendorsCryptoImpl",
            path: "Sources/Vendors/Crypto/OpenSSL",
            pkgConfig: "openssl",
            providers: [
                .apt(["libssl-dev"])
            ]
        ),
        .target(
            name: "_PartoutVendorsCrypto_C",
            dependencies: [
                "_PartoutVendorsCryptoCore_C",
                "_PartoutVendorsCryptoImpl"
            ],
            path: "Sources/Vendors/Crypto/CryptoOpenSSL_C"
        )
    ])
case .windows:
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutVendorsWindows_C",
            path: "Sources/Vendors/Windows_C"
        ),
        .target(
            name: "_PartoutVendorsCryptoImpl",
            dependencies: ["_PartoutVendorsWindows_C"],
            path: "Sources/Vendors/Crypto/Windows"
        )
    ])
default:
    break
}

package.targets.append(
    .testTarget(
        name: "_PartoutVendorsCrypto_CTests",
        dependencies: [
            "_PartoutVendorsCrypto_C", // now platform-independent
            "_PartoutVendorsPortable"
        ],
        path: "Tests/Vendors/Crypto_C",
        exclude: [
            "CryptoPerformanceTests.swift"
        ]
    )
)

// WireGuard not implemented yet on non-Apple
if OS.current == .apple {
    package.targets.append(
        .testTarget(
            name: "_PartoutVendorsWireGuardBackendTests",
            dependencies: [
                "_PartoutVendorsWireGuardBackend" // now platform-independent
            ],
            path: "Tests/Vendors/WireGuardBackend"
        )
    )
}

// MARK: - Deployment

import Foundation

enum OS {
    case android
    case apple
    case linux
    case windows

    // unfortunately, SwiftPM has no "when" conditionals on package
    // dependencies. we resort on some raw #if, which are reliable
    // as long as we don't cross-compile
    //
    // FIXME: #53, in fact, Android is wrong here because it's never compiled natively
    static var current: OS {
#if os(Windows)
        .windows
#elseif os(Linux)
        .linux
#elseif os(Android)
        .android
#else
        .apple
#endif
    }

    var platforms: [Platform] {
        switch self {
        case .android: [.android]
        case .apple: [.iOS, .macOS, .tvOS]
        case .linux: [.linux]
        case .windows: [.windows]
        }
    }
}

enum Area: CaseIterable {
    case api
    case documentation
    case openVPN
    case wireGuard

    static var `default`: Set<Area> {
        var included = Set(Area.allCases)
        if ProcessInfo.processInfo.environment["PARTOUT_DOCS"] != "1" {
            included.remove(.documentation)
        }
        if OS.current != .apple {
            included.remove(.wireGuard)
        }
        return included
    }
}

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
        path: "Sources/Core"
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
