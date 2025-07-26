// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// MARK: Package

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.160"
let checksum = "17a7494bf8295e5db5c6c0c9a5fcc6d7a5896d7e724e088b47e5e2b50ec0fb61"

// to download the core soruce
let coreSHA1 = "2b38fa48c7f1e8220331fc6368acb3ff4f9cbc15"

// deployment environment
let environment: Environment = .remoteBinary
let areas: Set<Area> = Area.defaultAreas

// FIXME: ###, set to false on deploy (check CI)
let isDevelopment = false
let isTestingOpenVPNDataPath = false

// the global settings for C targets
let cSettings: [CSetting] = [
    .unsafeFlags([
        "-Wall", "-Wextra"//, "-Werror"
    ])
]

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
            name: "PartoutImplementations",
            targets: ["PartoutImplementations"]
        )
    ],
    targets: [
        .target(
            name: "Partout",
            dependencies: {
                var list: [Target.Dependency] = [environment.coreDependency]
                list.append("PartoutProviders")
                if areas.contains(.api) {
                    list.append("PartoutAPI")
                    list.append("PartoutAPIBundle")
                }
                if areas.contains(.openVPN) {
                    list.append("PartoutOpenVPN")
                }
                if areas.contains(.wireGuard) {
                    list.append("PartoutWireGuard")
                }
                list.append("_PartoutVendorsCrypto_C")
                list.append("_PartoutVendorsPortable")
                if OS.current == .apple {
                    list.append("_PartoutVendorsApple")
                    list.append("_PartoutVendorsAppleNE")
                }
                return list
            }()
        ),
        .target(
            name: "PartoutImplementations",
            dependencies: {
                var list: [Target.Dependency] = []
                if areas.contains(.openVPN) {
                    list.append("_PartoutOpenVPNWrapper")
                }
                if areas.contains(.wireGuard) {
                    list.append("_PartoutWireGuardWrapper")
                }
                return list
            }(),
            path: "Sources/Implementations"
        ),
        .target(
            name: "PartoutProviders",
            dependencies: [environment.coreDependency],
            path: "Sources/Providers"
        ),
        .testTarget(
            name: "PartoutProvidersTests",
            dependencies: ["PartoutProviders"],
            path: "Tests/Providers",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: ["Partout"],
            path: "Tests/Partout",
            exclude: {
                var list: [String] = []
                if !areas.contains(.api) {
                    list.append("API")
                }
                if OS.current != .apple {
                    list.append("ProviderScriptingEngineTests.swift")
                }
                return list
            }(),
            resources: [
                .copy("Resources")
            ]
        )
    ]
)

if areas.contains(.documentation) {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0")
    )
}

// MARK: - OpenVPN

if areas.contains(.openVPN) {
    let mainTarget: String
    switch OS.current {
    case .android, .linux, .windows:
        mainTarget = "PartoutOpenVPNCross"
    default:
        mainTarget = "PartoutOpenVPNLegacy"
    }

    if isDevelopment {
        package.products.append(contentsOf: [
            .library(
                name: "_PartoutOpenVPNWrapper",
                targets: ["_PartoutOpenVPNWrapper"]
            ),
            .library(
                name: "PartoutOpenVPN",
                targets: ["PartoutOpenVPN"]
            )
        ])
    }
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOpenVPNWrapper",
            dependencies: [
                .target(name: mainTarget)
            ],
            path: "Sources/OpenVPN/Wrapper"
        ),
        .target(
            name: "PartoutOpenVPN",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/OpenVPN/Core"
        ),
        .testTarget(
            name: "_PartoutOpenVPNTests",
            dependencies: ["PartoutOpenVPN"],
            path: "Tests/OpenVPN/Core"
        )
    ])

    // legacy
    if OS.current == .apple {
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutCryptoOpenSSL_ObjC",
                dependencies: ["openssl-apple"],
                path: "Sources/OpenVPN/CryptoOpenSSL_ObjC"
            ),
            .target(
                name: "PartoutOpenVPNLegacy",
                dependencies: [
                    "PartoutOpenVPN",
                    "PartoutOpenVPNCross",
                    "_PartoutOpenVPNLegacy_ObjC"
                ],
                path: "Sources/OpenVPN/Legacy"
            ),
            .target(
                name: "_PartoutOpenVPNLegacy_ObjC",
                dependencies: ["_PartoutCryptoOpenSSL_ObjC"],
                path: "Sources/OpenVPN/Legacy_ObjC",
                exclude: [
                    "lib/COPYING",
                    "lib/Makefile",
                    "lib/README.LZO",
                    "lib/testmini.c"
                ]
            ),
            .testTarget(
                name: "_PartoutCryptoOpenSSL_ObjCTests",
                dependencies: ["_PartoutCryptoOpenSSL_ObjC"],
                path: "Tests/OpenVPN/CryptoOpenSSL_ObjC",
                exclude: [
                    "CryptoPerformanceTests.swift"
                ]
            ),
            .testTarget(
                name: "PartoutOpenVPNLegacyTests",
                dependencies: ["PartoutOpenVPNLegacy"],
                path: "Tests/OpenVPN/Legacy",
                exclude: isTestingOpenVPNDataPath ? [] : ["DataPathPerformanceTests.swift"],
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
            path: "Sources/OpenVPN/Cross_C"
        ),
        .target(
            name: "PartoutOpenVPNCross",
            dependencies: {
                var list: [Target.Dependency] = [
                    "PartoutOpenVPN",
                    "_PartoutOpenVPN_C",
                    "_PartoutVendorsPortable"
                ]
                if isTestingOpenVPNDataPath {
                    list.append("_PartoutOpenVPNLegacy_ObjC")
                }
                return list
            }(),
            path: "Sources/OpenVPN/Cross",
            exclude: {
                var list: [String] = []
                if !isTestingOpenVPNDataPath {
                    list.append("Internal/Legacy")
                }
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
            name: "PartoutOpenVPNCrossTests",
            dependencies: ["PartoutOpenVPNCross"],
            path: "Tests/OpenVPN/Cross",
            resources: [
                .process("Resources")
            ]
        )
    ])
}

// MARK: WireGuard

if areas.contains(.wireGuard) {
    if isDevelopment {
        package.products.append(contentsOf: [
            .library(
                name: "_PartoutWireGuardWrapper",
                targets: ["_PartoutWireGuardWrapper"]
            ),
            .library(
                name: "PartoutWireGuard",
                targets: ["PartoutWireGuard"]
            )
        ])
    }
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutWireGuardWrapper",
            dependencies: ["PartoutWireGuardCross"],
            path: "Sources/WireGuard/Wrapper"
        ),
        .target(
            name: "PartoutWireGuard",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/WireGuard/Core"
        ),
        .target(
            name: "_PartoutWireGuard_C",
            path: "Sources/WireGuard/Cross_C",
            publicHeadersPath: "."
        ),
        .target(
            name: "PartoutWireGuardCross",
            dependencies: [
                "_PartoutVendorsWireGuard",
                "_PartoutWireGuard_C",
                "PartoutWireGuard"
            ],
            path: "Sources/WireGuard/Cross",
        ),
        .testTarget(
            name: "_PartoutWireGuardTests",
            dependencies: ["PartoutWireGuard"],
            path: "Tests/WireGuard/Core"
        ),
        .testTarget(
            name: "PartoutWireGuardCrossTests",
            dependencies: ["PartoutWireGuardCross"],
            path: "Tests/WireGuard/Cross"
        )
    ])
}

// MARK: API

if areas.contains(.api) {
    if isDevelopment {
        package.products.append(
            .library(
                name: "PartoutAPI",
                targets: ["PartoutAPI"]
            )
        )
    }
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
            environment.coreDependency,
            "_PartoutVendorsPortable_C"
        ],
        path: "Sources/Vendors/Portable"
    ),
    .target(
        name: "_PartoutVendorsPortable_C",
        path: "Sources/Vendors/Portable_C"
    ),
    .target(
        name: "_PartoutVendorsWireGuardCore",
        path: "Sources/Vendors/WireGuard/Core"
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
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutVendorsApple",
            dependencies: [environment.coreDependency],
            path: "Sources/Vendors/Apple"
        ),
        .target(
            name: "_PartoutVendorsAppleNE",
            dependencies: [environment.coreDependency],
            path: "Sources/Vendors/AppleNE"
        )
    ])

    // crypto
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

    // WireGuard
    if areas.contains(.wireGuard) {
        package.dependencies.append(
            .package(url: "https://github.com/passepartoutvpn/wg-go-apple", from: "0.0.20250630")
        )
        package.targets.append(
            .target(
                name: "_PartoutVendorsWireGuard",
                dependencies: [
                    "_PartoutVendorsWireGuardCore",
                    "wg-go-apple"
                ],
                path: "Sources/Vendors/WireGuard/Go"
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
            name: "_PartoutVendorsWireGuardTests",
            dependencies: [
                "_PartoutVendorsWireGuard" // now platform-independent
            ],
            path: "Tests/Vendors/WireGuard"
        )
    )
}

// MARK: Deployment

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

    static var defaultAreas: Set<Area> {
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

    var coreDependency: Target.Dependency {
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
if isDevelopment {
    package.targets.append(contentsOf: [
        .testTarget(
            name: "PartoutCoreTests",
            dependencies: ["PartoutCoreWrapper"],
            path: "Tests/Core"
        )
    ])
}
