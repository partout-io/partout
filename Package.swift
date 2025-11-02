// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Foundation is required by ProcessInfo
import Foundation
import PackageDescription

// MARK: Environment

// Optional overrides from environment
let env = ProcessInfo.processInfo.environment
let envOS = env["PP_BUILD_OS"]
let envCMakeOutput = env["PP_BUILD_CMAKE_OUTPUT"]
let envDocs = env["PP_BUILD_DOCS"] == "1"

// MARK: Configuration

let areas = Set(Area.allCases)
let cryptoMode: CryptoMode? = .openSSL
let cmakeOutput = envCMakeOutput ?? ".bin/windows-arm64"

// Must be false in production (check in CI)
let isTestingOpenVPNDataPath = false

// MARK: - Package

// Build dynamic library on Android
var libraryType: Product.Library.LibraryType? = nil
var staticLibPrefix = ""
var openSSLLibs = "lib"
switch OS.current {
case .android:
    libraryType = .dynamic
case .windows:
    staticLibPrefix = "lib"
    openSSLLibs = "bin"
default:
    break
}

// The global settings for C targets
let globalCSettings: [CSetting] = [
    .unsafeFlags([
        "-Wall", "-Wextra"//, "-pedantic", "-Werror"
    ])
]

let package = Package(
    name: "partout",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "partout",
            type: libraryType,
            targets: ["Partout"]
        )
    ],
    targets: [
        .target(
            name: "Partout",
            dependencies: {
                // These are always included
                var list: [Target.Dependency] = [
                    "PartoutCore",
                    "PartoutOS"
                ]
                if cryptoMode != nil {
                    list.append("_PartoutCryptoImpl_C")
                    if areas.contains(.openVPN) {
                        list.append("PartoutOpenVPN")
                    }
                }
                if areas.contains(.wireGuard) {
                    list.append("PartoutWireGuard")
                }
                return list
            }(),
            swiftSettings: areas.compactMap(\.define).map {
                .define($0)
            }
        ),
        .target(
            name: "PartoutABI_C"
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: ["Partout"],
            swiftSettings: areas.compactMap(\.define).map {
                .define($0)
            }
        )
    ]
)

// Swift-DocC for documentation, do not include by default
if envDocs {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.1.0")
    )
}

// Wrapper = Core + OS
package.products.append(contentsOf: [
    .library(
        name: "PartoutCore",
        targets: ["PartoutCore"]
    ),
    .library(
        name: "PartoutOS",
        targets: ["PartoutOS"]
    )
])
package.targets.append(contentsOf: [
    .target(
        name: "PartoutCore",
        dependencies: [
            "PartoutABI_C",
            "PartoutCore_C",
            "PartoutFoundation"
        ]
    ),
    .target(
        name: "PartoutCore_C",
        cSettings: globalCSettings + {
            if OS.current == .windows {
                return [
                    .unsafeFlags(["-Ivendors/wintun"])
                ]
            }
            return []
        }()
    ),
    .target(
        name: "PartoutFoundation",
        exclude: ["Cross"]
        // FIXME: #228, Until Foundation is dropped
//        exclude: {
//            guard OS.current != .apple else {
//                return ["Cross"]
//            }
//            return []
//        }()
    ),
    .target(
        name: "PartoutOS",
        dependencies: ["PartoutCore"],
        exclude: {
            var list: [String] = []
            switch OS.current {
            case .apple:
#if swift(>=6.0)
                list.append(contentsOf: [
                    "AppleNE/Connection/NEUDPSocket.swift",
                    "AppleNE/Connection/NETCPSocket.swift",
                    "AppleNE/Connection/ValueObserver.swift",
                    "AppleNE/Extensions/NWUDPSessionState+Description.swift",
                    "AppleNE/Extensions/NWTCPConnectionState+Description.swift"
                ])
#endif
            default:
                list.append(contentsOf: ["Apple", "AppleNE"])
            }
            return list
        }()
    ),
    .testTarget(
        name: "PartoutCoreTests",
        dependencies: ["PartoutCore"]
    ),
    .testTarget(
        name: "PartoutOSTests",
        dependencies: ["PartoutOS"],
        exclude: {
            var list: [String] = []
            switch OS.current {
            case .apple:
#if swift(>=6.0)
                list.append("AppleNE/ValueObserverTests.swift")
#endif
            default:
                list.append(contentsOf: ["Apple", "AppleNE"])
            }
            return list
        }()
    )
])

// Standalone executables
package.targets.append(
    .executableTarget(
        name: "partoutd",
        dependencies: ["Partout"],
        path: "Executables/partoutd"
    )
)

// MARK: OpenVPN

// OpenVPN requires Crypto/TLS wrappers
if areas.contains(.openVPN), let cryptoMode {
    let includesLegacy = OS.current == .apple && cryptoMode == .openSSL

    // Deprecated LZO (to be deleted)
    let includesDeprecatedLZO = true
    let lzoDefine = "OPENVPN_DEPRECATED_LZO"
    let lzoCSettings: [CSetting] = true && includesDeprecatedLZO ? [.define(lzoDefine)] : []
    let lzoSwiftSettings: [SwiftSetting] = true && includesDeprecatedLZO ? [.define(lzoDefine)] : []

    package.products.append(
        .library(
            name: "PartoutOpenVPN",
            targets: ["PartoutOpenVPN"]
        )
    )
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutOpenVPN_C",
            dependencies: [
                "_LZO_C",
                "_PartoutCryptoImpl_C"
            ],
            cSettings: globalCSettings + lzoCSettings
        ),
        .target(
            name: "PartoutOpenVPN",
            dependencies: {
                var list: [Target.Dependency] = [
                    "PartoutOpenVPN_C",
                    "PartoutOS"
                ]
                if includesLegacy {
                    list.append("PartoutOpenVPN_ObjC")
                }
                return list
            }(),
            exclude: {
                var list: [String] = []
                if includesLegacy {
                    list.append("Cross/StandardOpenVPNParser+Cross.swift")
                } else {
                    list.append("Legacy")
                }
                return list
            }(),
            swiftSettings: {
                var list: [String] = []
                list.append("OPENVPN_WRAPPER_NATIVE")
                if includesLegacy {
                    list.append("OPENVPN_LEGACY")
                }
                if includesDeprecatedLZO {
                    list.append(lzoDefine)
                }
                return list.map {
                    .define($0)
                }
            }()
        ),
        .testTarget(
            name: "PartoutOpenVPNTests",
            dependencies: ["PartoutOpenVPN"],
            exclude: {
                var list: [String] = []
                if !includesLegacy {
                    list.append("Legacy")
                }
                if !isTestingOpenVPNDataPath {
                    list.append("Legacy/DataPathPerformanceTests.swift")
                }
                return list
            }(),
            resources: [
                .process("Resources")
            ],
            swiftSettings: lzoSwiftSettings
        )
    ])
    // Remove these ASAP
    package.targets.append(
        .target(
            name: "_LZO_C",
            path: "vendors/lzo",
            exclude: ["COPYING"],
            cSettings: globalCSettings
        )
    )
    if includesLegacy {
        package.targets.append(
            .target(
                name: "PartoutOpenVPN_ObjC",
                dependencies: [
                    "_LZO_C",
                    "_PartoutCryptoOpenSSL_ObjC",
                    "PartoutOpenVPN_C"
                ],
                cSettings: lzoCSettings
            )
        )
    }
}

// MARK: WireGuard

if areas.contains(.wireGuard) {
    let includesLegacy = OS.current == .apple
    switch OS.current {
    case .apple:
        // Require static wg-go backend
        package.dependencies.append(
            .package(url: "https://github.com/partout-io/wg-go-apple", from: "0.0.2025063103")
        )
        package.targets.append(
            .target(
                name: "PartoutWireGuard_C",
                dependencies: [
                    "PartoutCore_C",
                    "wg-go-apple"
                ]
            )
        )
    default:
        // Load wg-go backend dynamically
        package.targets.append(
            .target(
                name: "PartoutWireGuard_C",
                dependencies: ["PartoutCore_C"],
                cSettings: globalCSettings + [
                    .unsafeFlags(["-I\(cmakeOutput)/wg-go/include"])
                ]
            )
        )
    }
    package.products.append(
        .library(
            name: "PartoutWireGuard",
            targets: ["PartoutWireGuard"]
        )
    )
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutWireGuard",
            dependencies: [
                "PartoutOS",
                "PartoutWireGuard_C"
            ],
            exclude: !includesLegacy ? ["Legacy"] : []
        ),
        .testTarget(
            name: "PartoutWireGuardTests",
            dependencies: ["PartoutWireGuard"],
            exclude: !includesLegacy ? ["Legacy"] : []
        )
    ])
}

// MARK: - Crypto

switch cryptoMode {
case .openSSL:
    // OpenSSL-based crypto/TLS implementations
    switch OS.current {
    case .apple:
        package.dependencies.append(
            .package(url: "https://github.com/partout-io/openssl-apple", from: "3.5.500")
        )
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutCryptoImpl_C",
                dependencies: [
                    "openssl-apple",
                    "PartoutCore_C"
                ],
                path: "Sources/PartoutCrypto/OpenSSL_C"
            ),
            // Legacy for OpenVPN
            .target(
                name: "_PartoutCryptoOpenSSL_ObjC",
                dependencies: ["openssl-apple"],
                path: "Sources/PartoutCrypto/OpenSSL_ObjC"
            ),
            .testTarget(
                name: "PartoutCryptoOpenSSL_ObjCTests",
                dependencies: ["_PartoutCryptoOpenSSL_ObjC"],
                exclude: [
                    "CryptoPerformanceTests.swift"
                ]
            )
        ])
    default:
        package.targets.append(
            .target(
                name: "_PartoutCryptoImpl_C",
                dependencies: ["PartoutCore_C"],
                path: "Sources/PartoutCrypto/OpenSSL_C",
                cSettings: globalCSettings + [
                    .unsafeFlags(["-I\(cmakeOutput)/openssl/include"])
                ],
                linkerSettings: [
                    .unsafeFlags(["-L\(cmakeOutput)/openssl/\(openSSLLibs)"]),
                    // WARNING: order matters, ssl then crypto
                    .linkedLibrary("\(staticLibPrefix)ssl"),
                    .linkedLibrary("\(staticLibPrefix)crypto")
                ]
            )
        )
    }
case .native:
    // Crypto with OS routines, TLS with MbedTLS
    package.targets.append(
        .target(
            name: "_PartoutCryptoImpl_C",
            dependencies: ["PartoutCore_C"],
            path: "Sources/PartoutCrypto/Native_C",
            exclude: {
                // Pick current OS by removing it from exclusions
                var list = Set(OS.allCases)
                list.remove(.current)
                return list.map { "src/\($0.rawValue)" }
            }(),
            cSettings: globalCSettings + [
                .unsafeFlags(["-I\(cmakeOutput)/mbedtls/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(cmakeOutput)/mbedtls/lib"]),
                // WARNING: order matters
                .linkedLibrary("mbedtls"),
                .linkedLibrary("mbedx509"),
                .linkedLibrary("mbedcrypto")
            ]
        )
    )
default:
    break
}

// Include concrete crypto targets if supported
if cryptoMode != nil {
    package.products.append(
        .library(
            name: "PartoutCrypto",
            targets: ["_PartoutCryptoImpl_C"]
        )
    )
    package.targets.append(contentsOf: [
        .testTarget(
            name: "PartoutCryptoTests",
            dependencies: [
                "_PartoutCryptoImpl_C",
                "PartoutOS"
            ],
            exclude: [
                "CryptoPerformanceTests.swift"
            ]
        )
    ])
}

// MARK: - Configuration structures

enum Area: CaseIterable {
    case openVPN
    case wireGuard

    var define: String? {
        switch self {
        case .openVPN: cryptoMode != nil ? "PARTOUT_OPENVPN" : nil
        case .wireGuard: "PARTOUT_WIREGUARD"
        }
    }
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
