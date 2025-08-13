// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation // required for ProcessInfo
import PackageDescription

// MARK: Package

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.174"
let checksum = "e882ea65c2d42fbff5655a3d1ecec8b1c8d88f8260100f104099791e932becc5"

// optional overrides from environment
let env = ProcessInfo.processInfo.environment
let envOS = env["PARTOUT_OS"]
let envCoreDeployment = env["PARTOUT_CORE"].map(CoreDeployment.init(rawValue:)) ?? nil
let envWithDocs = env["PARTOUT_DOCS"] == "1"

// included areas and environment
let areas: Set<Area> = Area.defaultAreas
let coreDeployment = envCoreDeployment ?? .remoteBinary
let coreSourceSHA1 = "ca8b0496806a1835bcd6ff465129f18b5e5eaadf"

// must be false in production (check in CI)
let isDevelopment = false
let isTestingOpenVPNDataPath = false

// PartoutCore binaries only on non-Apple
guard OS.current == .apple || ![.remoteBinary, .localBinary].contains(coreDeployment) else {
    fatalError("Core binary only available on Apple platforms")
}

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
            type: .static,
            targets: ["Partout"]
        ),
        .library(
            name: "PartoutImplementations",
            type: .static,
            targets: ["PartoutImplementations"]
        )
    ],
    targets: [
        .target(
            name: "Partout",
            dependencies: {
                var list: [Target.Dependency] = []

                // always included
                list.append(coreDeployment.dependency)
                list.append("PartoutABI")
                list.append("PartoutProviders")
                list.append("_PartoutVendorsPortable")

                // conditional
                if areas.contains(.api) {
                    list.append("PartoutAPI")
                    list.append("PartoutAPIBundle")
                }
                if areas.contains(.crypto) {
                    list.append("_PartoutCrypto_C")
                }
                if areas.contains(.openVPN) {
                    list.append("PartoutOpenVPN")
                }
                if areas.contains(.wireGuard) {
                    list.append("PartoutWireGuard")
                }

                // OS-dependent
                switch OS.current {
                case .apple:
                    list.append("_PartoutVendorsApple")
                    list.append("_PartoutVendorsAppleNE")
                default:
                    break
                }

                return list
            }(),
            exclude: {
                var list: [String] = []
                if !areas.contains(.api) {
                    list.append("API")
                }
                return list
            }(),
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
            }()
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

package.targets.append(contentsOf: [
    .target(
        name: "_PartoutABI_C",
        path: "Sources/ABI/Library_C"
    ),
    .target(
        name: "PartoutABI",
        dependencies: ["_PartoutABI_C"],
        path: "Sources/ABI/Library"
    ),
    .target(
        name: "PartoutProviders",
        dependencies: [coreDeployment.dependency],
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
            path: "Tests/OpenVPN/Core",
            resources: [
                .process("Resources")
            ]
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
            dependencies: [
                "_PartoutCrypto_C",
                "_PartoutVendorsTLS_C"
            ],
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
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutAPI",
            dependencies: ["PartoutProviders"],
            path: "Sources/API/Library"
        ),
        .target(
            name: "PartoutAPIBundle",
            dependencies: [
                "PartoutAPI",
                "PartoutProviders"
            ],
            path: "Sources/API/Bundle",
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
        name: "_PartoutVendorsPortable",
        dependencies: [
            coreDeployment.dependency,
            "_PartoutVendorsPortable_C"
        ],
        path: "Sources/Vendors/Portable"
    ),
    .target(
        name: "_PartoutVendorsPortable_C",
        path: "Sources/Vendors/Portable_C"
    ),
    .testTarget(
        name: "_PartoutVendorsPortableTests",
        dependencies: ["_PartoutVendorsPortable"],
        path: "Tests/Vendors/Portable"
    )
])

// MARK: OS

switch OS.current {
case .android:
    if areas.contains(.crypto) {
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutVendorsOpenSSL",
                path: "Sources/Vendors/OpenSSL",
                // use .artifactbundle once supported
                linkerSettings: [
                    .unsafeFlags(["-Lvendors/lib/android/arm64"]),
                    // WARNING: order matters, ssl then crypto
                    .linkedLibrary("ssl"),
                    .linkedLibrary("crypto")
                ]
            ),
            .target(
                name: "_PartoutCrypto_C",
                dependencies: [
                    "_PartoutCryptoCore_C",
                    "_PartoutVendorsOpenSSL"
                ],
                path: "Sources/Crypto/CryptoOpenSSL_C"
            ),
            .target(
                name: "_PartoutVendorsTLS_C",
                dependencies: [
                    "_PartoutVendorsOpenSSL",
                    "_PartoutVendorsTLSCore_C"
                ],
                path: "Sources/Crypto/TLSOpenSSL_C"
            )
        ])
    }
case .apple:
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutVendorsApple",
            dependencies: [coreDeployment.dependency],
            path: "Sources/Vendors/Apple"
        ),
        .target(
            name: "_PartoutVendorsAppleNE",
            dependencies: [coreDeployment.dependency],
            path: "Sources/Vendors/AppleNE"
        ),
        .testTarget(
            name: "_PartoutVendorsAppleTests",
            dependencies: ["_PartoutVendorsApple"],
            path: "Tests/Vendors/Apple"
        ),
        .testTarget(
            name: "_PartoutVendorsAppleNETests",
            dependencies: ["_PartoutVendorsAppleNE"],
            path: "Tests/Vendors/AppleNE"
        )
    ])
    if areas.contains(.crypto) {
        package.dependencies.append(
            .package(url: "https://github.com/passepartoutvpn/openssl-apple", exact: "3.5.200")
        )
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutVendorsOpenSSL",
                dependencies: ["openssl-apple"],
                path: "Sources/Vendors/OpenSSL",
                exclude: [
                    "include/shim.h",
                    "module.modulemap"
                ]
            ),
            .target(
                name: "_PartoutCrypto_C",
                dependencies: [
                    "_PartoutCryptoCore_C",
                    "_PartoutVendorsOpenSSL"
                ],
                path: "Sources/Crypto/CryptoOpenSSL_C"
            ),
            .target(
                name: "_PartoutVendorsTLS_C",
                dependencies: [
                    "_PartoutVendorsOpenSSL",
                    "_PartoutVendorsTLSCore_C"
                ],
                path: "Sources/Crypto/TLSOpenSSL_C"
            )
        ])
    }
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
    if areas.contains(.crypto) {
        package.targets.append(contentsOf: [
            .systemLibrary(
                name: "_PartoutVendorsOpenSSL",
                path: "Sources/Vendors/OpenSSL",
                pkgConfig: "openssl",
                providers: [
                    .apt(["libssl-dev"])
                ]
            ),
            .target(
                name: "_PartoutCrypto_C",
                dependencies: [
                    "_PartoutCryptoCore_C",
                    "_PartoutVendorsOpenSSL"
                ],
                path: "Sources/Crypto/CryptoOpenSSL_C"
            ),
            .target(
                name: "_PartoutVendorsTLS_C",
                dependencies: [
                    "_PartoutVendorsOpenSSL",
                    "_PartoutVendorsTLSCore_C"
                ],
                path: "Sources/Crypto/TLSOpenSSL_C"
            )
        ])
    }
case .windows:
    if areas.contains(.crypto) {
        package.targets.append(
            .target(
                name: "_PartoutCrypto_C",
                dependencies: [
                    "_PartoutCryptoCore_C",
                    "_PartoutVendorsPortable_C"
                ],
                path: "Sources/Crypto/CryptoWindows_C"
            )
        )
    }
}

if areas.contains(.crypto) {
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutCryptoCore_C",
            dependencies: ["_PartoutVendorsPortable_C"],
            path: "Sources/Crypto/CryptoCore_C"
        ),
        .target(
            name: "_PartoutVendorsTLSCore_C",
            dependencies: [
                "_PartoutCryptoCore_C",
                "_PartoutVendorsPortable_C",
            ],
            path: "Sources/Crypto/TLSCore_C"
        ),
        .testTarget(
            name: "_PartoutCryptoTests",
            dependencies: [
                "_PartoutCrypto_C", // now platform-independent
                "_PartoutVendorsPortable"
            ],
            path: "Tests/Crypto",
            exclude: [
                "CryptoPerformanceTests.swift"
            ]
        )
    ])
}

if areas.contains(.wireGuard) {
    package.targets.append(
        .target(
            name: "_PartoutVendorsWireGuardCore",
            path: "Sources/Vendors/WireGuard/Core"
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
}

// MARK: - Deployment

enum OS: String {
    case android
    case apple
    case linux
    case windows

    // Unfortunately, SwiftPM has no "when" conditionals on package
    // dependencies. We resort on some raw #if, which are reliable
    // as long as we don't cross-compile.
    static var current: OS {
        // Android is never compiled natively, therefore #if os(Android)
        // would be wrong here. Resort to an explicit env variable.
        if let envOS {
            guard let os = OS(rawValue: envOS) else {
                fatalError("Unrecognized OS '\(envOS)'")
            }
            return os
        }
#if os(Windows)
        return .windows
#elseif os(Linux)
        return .linux
#else
        return .apple
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
    case crypto
    case documentation
    case openVPN
    case wireGuard

    static var defaultAreas: Set<Area> {
        var included = Set(Area.allCases)
        if !envWithDocs {
            included.remove(.documentation)
        }
        if OS.current != .apple {
            included.remove(.wireGuard)
        }
        return included
    }
}

enum CoreDeployment: String, RawRepresentable {
    case remoteBinary
    case remoteSource
    case localBinary
    case localSource
    case documentation

    var dependency: Target.Dependency {
        switch self {
        case .documentation: "PartoutCore"
        default: "PartoutCoreWrapper"
        }
    }
}

switch coreDeployment {
case .remoteBinary:
    package.targets.append(.binaryTarget(
        name: "PartoutCoreWrapper",
        url: "https://github.com/passepartoutvpn/partout/releases/download/\(version)/\(binaryFilename)",
        checksum: checksum
    ))
case .remoteSource:
    package.dependencies.append(
        .package(url: "git@github.com:passepartoutvpn/partout-core.git", revision: coreSourceSHA1)
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
