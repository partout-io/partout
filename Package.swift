// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Foundation is required by ProcessInfo
import Foundation
import PackageDescription

// MARK: Environment

// Optional overrides from environment
let env = ProcessInfo.processInfo.environment
let envOS = env["PP_BUILD_OS"]
let envCoreDeployment = env["PP_BUILD_CORE"].map(CoreDeployment.init(rawValue:)) ?? nil
let envCMakeOutput = env["PP_BUILD_CMAKE_OUTPUT"]

// MARK: Configuration

let areas = Set(Area.allCases)
let cryptoMode: CryptoMode? = .openSSL
var wgMode: WireGuardMode? = .wgGo
let coreDeployment = envCoreDeployment ?? .remoteBinary
let cmakeOutput = envCMakeOutput ?? "bin/darwin-arm64"

// Must be false in production (check in CI)
let isTestingOpenVPNDataPath = false

// FIXME: #118, restore WireGuard when properly integrated
if OS.current != .apple {
    wgMode = nil
}

// MARK: - Package

// PartoutCore binaries only available on Apple platforms
guard OS.current == .apple || coreDeployment != .remoteBinary else {
    fatalError("Core binary only available on Apple platforms")
}

// Build dynamic library on Android
var libraryType: Product.Library.LibraryType? = nil
var staticLibPrefix = ""
switch OS.current {
case .android:
    libraryType = .dynamic
case .windows:
    staticLibPrefix = "lib"
default:
    break
}

// The global settings for C targets
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
            type: libraryType,
            targets: ["Partout"]
        ),
        .library(
            name: "PartoutInterfaces",
            targets: ["PartoutInterfaces"]
        )
    ],
    targets: [
        .target(
            name: "Partout",
            dependencies: {
                var list: [Target.Dependency] = []
                list.append("Partout_C")
                list.append("PartoutInterfaces")

                // Implementations and third parties
                if cryptoMode != nil {
                    list.append("_PartoutCryptoImpl_C")
                    if areas.contains(.openVPN) {
                        list.append("_PartoutOpenVPNWrapper")
                    }
                }
                if areas.contains(.wireGuard), wgMode != nil {
                    list.append("_PartoutVendorsWireGuardImpl")
                    if areas.contains(.wireGuard) {
                        list.append("_PartoutWireGuardWrapper")
                    }
                }
                return list
            }()
        ),
        .target(
            name: "Partout_C",
            dependencies: ["_PartoutOSPortable_C"]
        ),
        .target(
            name: "PartoutInterfaces",
            dependencies: {
                var list: [Target.Dependency] = []

                // These are always included
                list.append("_PartoutOSWrapper")
                list.append("PartoutProviders")

                // Optional includes
                if areas.contains(.api) {
                    list.append("PartoutAPI")
                }
                if areas.contains(.openVPN) {
                    list.append("PartoutOpenVPN")
                }
                if areas.contains(.wireGuard) {
                    list.append("PartoutWireGuard")
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
        .testTarget(
            name: "PartoutTests",
            dependencies: ["Partout"],
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

// Wrapper = Core + Portable + OS-specific
package.targets.append(contentsOf: [
    .target(
        name: "_PartoutOSWrapper",
        dependencies: {
            var list: [Target.Dependency] = ["_PartoutOSPortable"]
            switch OS.current {
            case .android:
                list.append("_PartoutOSAndroid")
            case .apple:
                list.append("_PartoutOSApple")
            case .linux:
                list.append("_PartoutOSLinux")
            case .windows:
                list.append("_PartoutOSWindows")
            }
            return list
        }(),
        path: "Sources/OS/Wrapper"
    ),
    .target(
        name: "PartoutProviders",
        dependencies: ["_PartoutOSPortable"]
    ),
    .testTarget(
        name: "PartoutProvidersTests",
        dependencies: ["PartoutProviders"],
        resources: [
            .process("Resources")
        ]
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
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutAPI",
            dependencies: ["PartoutProviders"],
            resources: [
                .copy("JSON")
            ]
        ),
        .testTarget(
            name: "PartoutAPITests",
            dependencies: ["PartoutAPI"]
        )
    ])
}

// MARK: - OpenVPN

if areas.contains(.openVPN) {
    package.products.append(
        .library(
            name: "PartoutOpenVPN",
            targets: ["PartoutOpenVPN"]
        )
    )
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutOpenVPN",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/PartoutOpenVPN/Interfaces"
        ),
        .testTarget(
            name: "PartoutOpenVPNTests",
            dependencies: ["PartoutOpenVPN"],
            path: "Tests/PartoutOpenVPN/Interfaces",
            resources: [
                .process("Resources")
            ]
        )
    ])

    // Implementation requires Crypto/TLS wrappers
    if cryptoMode != nil {
        let includesLegacy = OS.current == .apple && cryptoMode == .openSSL
        let mainTarget = includesLegacy ? "PartoutOpenVPNLegacy" : "PartoutOpenVPNCross"

        package.products.append(
            .library(
                name: "_PartoutOpenVPNWrapper",
                targets: ["_PartoutOpenVPNWrapper"]
            )
        )
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutOpenVPNWrapper",
                dependencies: [
                    .target(name: mainTarget)
                ],
                path: "Sources/PartoutOpenVPN/Wrapper"
            )
        ])

        // Legacy implementation (only on Apple)
        if includesLegacy {
            package.targets.append(contentsOf: [
                .target(
                    name: "_PartoutCryptoOpenSSL_ObjC",
                    dependencies: ["openssl-apple"],
                    path: "Sources/PartoutOpenVPN/LegacyCryptoOpenSSL_ObjC"
                ),
                .target(
                    name: "PartoutOpenVPNLegacy",
                    dependencies: [
                        "PartoutOpenVPN",
                        "PartoutOpenVPNCross",
                        "_PartoutOpenVPNLegacy_ObjC"
                    ],
                    path: "Sources/PartoutOpenVPN/Legacy"
                ),
                .target(
                    name: "_PartoutOpenVPNLegacy_ObjC",
                    dependencies: ["_PartoutCryptoOpenSSL_ObjC"],
                    path: "Sources/PartoutOpenVPN/Legacy_ObjC",
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
                    path: "Tests/PartoutOpenVPN/LegacyCryptoOpenSSL_ObjC",
                    exclude: [
                        "CryptoPerformanceTests.swift"
                    ]
                ),
                .testTarget(
                    name: "PartoutOpenVPNLegacyTests",
                    dependencies: ["PartoutOpenVPNLegacy"],
                    path: "Tests/PartoutOpenVPN/Legacy",
                    exclude: isTestingOpenVPNDataPath ? [] : ["DataPathPerformanceTests.swift"],
                    resources: [
                        .process("Resources")
                    ]
                )
            ])
        }

        // Cross-platform implementation (experimental)
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutOpenVPN_C",
                dependencies: ["_PartoutCryptoImpl_C"],
                path: "Sources/PartoutOpenVPN/Cross_C"
            ),
            .target(
                name: "PartoutOpenVPNCross",
                dependencies: {
                    var list: [Target.Dependency] = [
                        "PartoutOpenVPN",
                        "_PartoutOpenVPN_C",
                        "_PartoutOSPortable"
                    ]
                    if isTestingOpenVPNDataPath {
                        list.append("_PartoutOpenVPNLegacy_ObjC")
                    }
                    return list
                }(),
                path: "Sources/PartoutOpenVPN/Cross",
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
                path: "Tests/PartoutOpenVPN/Cross",
                resources: [
                    .process("Resources")
                ]
            )
        ])
    }
}

// MARK: WireGuard

if areas.contains(.wireGuard) {
    package.products.append(
        .library(
            name: "PartoutWireGuard",
            targets: ["PartoutWireGuard"]
        )
    )
    package.targets.append(
        .target(
            name: "PartoutWireGuard",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/PartoutWireGuard/Interfaces"
        )
    )

    // Implementation requires a WireGuard backend
    if wgMode != nil {
        package.products.append(
            .library(
                name: "_PartoutWireGuardWrapper",
                targets: ["_PartoutWireGuardWrapper"]
            ),
        )
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutWireGuardWrapper",
                dependencies: ["PartoutWireGuardCross"],
                path: "Sources/PartoutWireGuard/Wrapper"
            ),
            .target(
                name: "_PartoutWireGuard_C",
                path: "Sources/PartoutWireGuard/Cross_C",
                publicHeadersPath: "."
            ),
            .target(
                name: "PartoutWireGuardCross",
                dependencies: [
                    "_PartoutVendorsWireGuardImpl",
                    "_PartoutWireGuard_C",
                    "PartoutWireGuard"
                ],
                path: "Sources/PartoutWireGuard/Cross",
            ),
            .testTarget(
                name: "PartoutWireGuardTests",
                dependencies: ["PartoutWireGuard"],
                path: "Tests/PartoutWireGuard/Interfaces"
            ),
            .testTarget(
                name: "PartoutWireGuardCrossTests",
                dependencies: ["PartoutWireGuardCross"],
                path: "Tests/PartoutWireGuard/Cross"
            )
        ])
    }
}

// MARK: - Vendors

// MARK: Crypto

switch cryptoMode {
case .openSSL:
    let vendorTarget: Target.Dependency
    let vendorCSettings: [CSetting]?

    switch OS.current {
    case .apple:
        vendorTarget = "openssl-apple"
        vendorCSettings = nil
        package.dependencies.append(
            .package(url: "https://github.com/passepartoutvpn/openssl-apple", exact: "3.5.200")
        )
    case .linux:
        vendorTarget = "openssl-linux"
        vendorCSettings = nil
        package.targets.append(
            .systemLibrary(
                name: "openssl-linux",
                path: "Sources/Vendors/OpenSSL",
                pkgConfig: "openssl",
                providers: [
                    .apt(["libssl-dev"])
                ]
            )
        )
    default:
        vendorTarget = "openssl-cmake"
        vendorCSettings = [
            .unsafeFlags(["-I\(cmakeOutput)/openssl/include"])
        ]
        package.targets.append(
            .target(
                name: "openssl-cmake",
                path: "Sources/Vendors/OpenSSL",
                exclude: [
                    "shim.h",
                    "module.modulemap"
                ],
                publicHeadersPath: ".",
                linkerSettings: [
                    .unsafeFlags(["-L\(cmakeOutput)/openssl/lib"]),
                    // WARNING: order matters, ssl then crypto
                    .linkedLibrary("\(staticLibPrefix)ssl"),
                    .linkedLibrary("\(staticLibPrefix)crypto")
                ]
            )
        )
    }

    // OpenSSL-based crypto/TLS implementations
    package.targets.append(
        .target(
            name: "_PartoutCryptoImpl_C",
            dependencies: [
                "_PartoutOSPortable_C",
                vendorTarget
            ],
            path: "Sources/Impl/CryptoOpenSSL_C",
            cSettings: vendorCSettings
        )
    )
case .native: // MbedTLS + OS
    let vendorTarget: Target.Dependency
    let vendorCSettings: [CSetting]?

    // Pick current OS by removing it from exclusions
    let exclusions = {
        var list = Set(OS.allCases)
        list.remove(.current)
        return list.map { "src/\($0.rawValue)" }
    }()

    switch OS.current {
    case .linux:
        vendorTarget = "mbedtls-linux"
        vendorCSettings = nil
        package.targets.append(
            .systemLibrary(
                name: "mbedtls-linux",
                path: "Sources/Vendors/MbedTLS",
                providers: [
                    .apt(["libmbedtls-dev"])
                ]
            )
        )
    default:
        vendorTarget = "mbedtls-cmake"
        vendorCSettings = [
            .unsafeFlags(["-I\(cmakeOutput)/mbedtls/include"])
        ]
        package.targets.append(
            .target(
                name: "mbedtls-cmake",
                path: "Sources/Vendors/MbedTLS",
                exclude: [
                    "shim.h",
                    "module.modulemap"
                ],
                publicHeadersPath: ".",
                linkerSettings: [
                    .unsafeFlags(["-L\(cmakeOutput)/mbedtls/lib"]),
                    // WARNING: order matters
                    .linkedLibrary("\(staticLibPrefix)mbedtls"),
                    .linkedLibrary("\(staticLibPrefix)mbedx509"),
                    .linkedLibrary("\(staticLibPrefix)mbedcrypto")
                ]
            )
        )
    }

    // Crypto with OS routines, TLS with MbedTLS
    package.targets.append(
        .target(
            name: "_PartoutCryptoImpl_C",
            dependencies: [
                "_PartoutOSPortable_C",
                vendorTarget
            ],
            path: "Sources/Impl/CryptoNative_C",
            exclude: exclusions,
            cSettings: vendorCSettings
        )
    )
default:
    break
}

// Include concrete crypto targets if supported
if cryptoMode != nil {
    package.products.append(
        .library(
            name: "_PartoutCrypto",
            targets: ["_PartoutCryptoImpl_C"]
        )
    )
    package.targets.append(contentsOf: [
        .testTarget(
            name: "PartoutCryptoTests",
            dependencies: [
                "_PartoutCryptoImpl_C",
                "_PartoutOSPortable"
            ],
            exclude: [
                "CryptoPerformanceTests.swift"
            ]
        )
    ])
}

// MARK: WireGuard

// Generic backend interface to implement
if areas.contains(.wireGuard) {
    switch wgMode {
        case .wgGo:
            // Use portable Go backend for WireGuard
            switch OS.current {
            case .apple:
                package.dependencies.append(
                    .package(url: "https://github.com/passepartoutvpn/wg-go-apple", from: "0.0.20250630")
                )
                package.targets.append(
                    .target(
                        name: "_PartoutVendorsWireGuardImpl",
                        dependencies: [
                            "PartoutWireGuard",
                            "wg-go-apple"
                        ],
                        path: "Sources/Vendors/WireGuardGo"
                    )
                )
            default:
                break
            }
        default:
            break
    }

    // Include back tests if supported
    if wgMode != nil {
        package.targets.append(contentsOf: [
            .testTarget(
                name: "_PartoutVendorsWireGuardImplTests",
                dependencies: ["_PartoutVendorsWireGuardImpl"],
                path: "Tests/Vendors/WireGuard"
            )
        ])
    }
}

// MARK: - OS

// Cross-platform utilities
package.targets.append(contentsOf: [
    .target(
        name: "_PartoutOSPortable",
        dependencies: [
            coreDeployment.dependency,
            "_PartoutOSPortable_C"
        ],
        path: "Sources/OS/Portable"
    ),
    .target(
        name: "_PartoutOSPortable_C",
        path: "Sources/OS/Portable_C"
    ),
    .testTarget(
        name: "_PartoutOSPortableTests",
        dependencies: ["_PartoutOSPortable"],
        path: "Tests/OS/Portable"
    )
])

// Targets relying on OS-specific frameworks
switch OS.current {
case .android:
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOSAndroid",
            dependencies: [
                "_PartoutOSAndroid_C",
                "_PartoutOSPortable"
            ],
            path: "Sources/OS/Android"
        ),
        .target(
            name: "_PartoutOSAndroid_C",
            dependencies: ["_PartoutOSPortable_C"],
            path: "Sources/OS/Android_C"
        )
    ])
case .apple:
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOSApple",
            dependencies: [
                coreDeployment.dependency,
                "_PartoutOSApple_C",
                "_PartoutOSAppleNE"
            ],
            path: "Sources/OS/Apple"
        ),
        .target(
            name: "_PartoutOSApple_C",
            dependencies: ["_PartoutOSPortable_C"],
            path: "Sources/OS/Apple_C"
        ),
        .target(
            name: "_PartoutOSAppleNE",
            dependencies: [coreDeployment.dependency],
            path: "Sources/OS/AppleNE",
            exclude: {
#if swift(>=6.0)
                [
                    "Connection/NEUDPSocket.swift",
                    "Connection/NETCPSocket.swift",
                    "Connection/ValueObserver.swift",
                    "Extensions/NWUDPSessionState+Description.swift",
                    "Extensions/NWTCPConnectionState+Description.swift"
                ]
#else
                []
#endif
            }()
        ),
        .testTarget(
            name: "_PartoutOSAppleTests",
            dependencies: ["_PartoutOSApple"],
            path: "Tests/OS/Apple"
        ),
        .testTarget(
            name: "_PartoutOSAppleNETests",
            dependencies: ["_PartoutOSAppleNE"],
            path: "Tests/OS/AppleNE",
            exclude: {
#if swift(>=6.0)
                [
                    "ValueObserverTests.swift"
                ]
#else
                []
#endif
            }()
        )
    ])
case .linux:
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOSLinux",
            dependencies: [
                "_PartoutOSLinux_C",
                "_PartoutOSPortable"
            ],
            path: "Sources/OS/Linux"
        ),
        .target(
            name: "_PartoutOSLinux_C",
            dependencies: ["_PartoutOSPortable_C"],
            path: "Sources/OS/Linux_C"
        )
    ])
case .windows:
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOSWindows",
            dependencies: [
                "_PartoutOSWindows_C",
                "_PartoutOSPortable"
            ],
            path: "Sources/OS/Windows"
        ),
        .target(
            name: "_PartoutOSWindows_C",
            dependencies: ["_PartoutOSPortable_C"],
            path: "Sources/OS/Windows_C"
        )
    ])
}

// MARK: - Configuration structures

enum Area: CaseIterable {
    case api
    case openVPN
    case wireGuard
}

enum OS: String, CaseIterable {
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

enum CryptoMode {
    case openSSL
    case native
}

enum WireGuardMode {
    case wgGo
}

// MARK: - Core

// MARK: Auto-generated (do not modify)

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.182"
let checksum = "47f8918493eccd1f9ce922e34abb1745d5277e1329118b1a9f48ddbc80a13f08"

enum CoreDeployment: String, RawRepresentable {
    case remoteBinary
    case localSource

    var dependency: Target.Dependency {
        "PartoutCoreWrapper"
    }
}

switch coreDeployment {
case .remoteBinary:
    package.targets.append(.binaryTarget(
        name: "PartoutCoreWrapper",
        url: "https://github.com/passepartoutvpn/partout/releases/download/\(version)/\(binaryFilename)",
        checksum: checksum
    ))
case .localSource:
    package.dependencies.append(
        .package(path: "vendors/core")
    )
    package.targets.append(.target(
        name: "PartoutCoreWrapper",
        dependencies: [
            .product(name: "PartoutCore", package: "core")
        ],
        path: "Sources/Vendors/Core"
    ))
}
package.targets.append(contentsOf: [
    .testTarget(
        name: "PartoutCoreTests",
        dependencies: ["PartoutCoreWrapper"],
        path: "Tests/Vendors/Core"
    )
])
