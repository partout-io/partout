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
let coreDeployment = envCoreDeployment ?? .remoteBinary
let cmakeOutput = envCMakeOutput ?? ".bin/windows-arm64"

// Must be false in production (check in CI)
let isTestingOpenVPNDataPath = false

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
let globalCSettings: [CSetting] = [
    .unsafeFlags([
        "-Wall", "-Wextra"//, "-pedantic", "-Werror"
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
        )
    ],
    targets: [
        .target(
            name: "Partout",
            dependencies: {
                // These are always included
                var list: [Target.Dependency] = [
                    "Partout_C",
                    "PartoutOS",
                    "PartoutProviders"
                ]
                // Optional
                if areas.contains(.api) {
                    list.append("PartoutAPI")
                }
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
            exclude: {
                var list: [String] = []
                if !areas.contains(.api) {
                    list.append("API")
                }
                return list
            }(),
            swiftSettings: areas.compactMap(\.define).map {
                .define($0)
            }
        ),
        .target(
            name: "Partout_C"
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
            ],
            swiftSettings: areas.compactMap(\.define).map {
                .define($0)
            }
        )
    ]
)

// Wrapper = Core + OS/Portable + Providers
package.targets.append(contentsOf: [
    .target(
        name: "PartoutOS_C",
        dependencies: ["PartoutCoreWrapper"],
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
        name: "PartoutOS",
        dependencies: [
            "Partout_C",
            "PartoutOS_C"
        ],
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
    .target(
        name: "PartoutProviders",
        dependencies: ["PartoutOS"]
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
    ),
    .testTarget(
        name: "PartoutProvidersTests",
        dependencies: ["PartoutProviders"],
        resources: [
            .process("Resources")
        ]
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
            name: "PartoutOpenVPN_ObjC",
            dependencies: [
                "_LZO_C",
                "_PartoutCryptoOpenSSL_ObjC",
                "PartoutOpenVPN_C"
            ],
            cSettings: lzoCSettings
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
    // Remove LZO ASAP
    package.targets.append(
        .target(
            name: "_LZO_C",
            path: "vendors/lzo",
            exclude: ["COPYING"],
            cSettings: globalCSettings
        )
    )
}

// MARK: WireGuard

if areas.contains(.wireGuard) {
    let includesLegacy = OS.current == .apple
    switch OS.current {
    case .apple:
        // Require static wg-go backend
        package.dependencies.append(
            .package(url: "https://github.com/passepartoutvpn/wg-go-apple", from: "0.0.2025063102")
        )
        package.targets.append(
            .target(
                name: "PartoutWireGuard_C",
                dependencies: [
                    "PartoutOS_C",
                    "wg-go-apple"
                ]
            )
        )
    default:
        // Load wg-go backend dynamically
        package.targets.append(
            .target(
                name: "PartoutWireGuard_C",
                dependencies: ["PartoutOS_C"],
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
            .package(url: "https://github.com/passepartoutvpn/openssl-apple", exact: "3.5.200")
        )
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutCryptoImpl_C",
                dependencies: [
                    "openssl-apple",
                    "PartoutOS_C"
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
                dependencies: ["PartoutOS_C"],
                path: "Sources/PartoutCrypto/OpenSSL_C",
                cSettings: globalCSettings + [
                    .unsafeFlags(["-I\(cmakeOutput)/openssl/include"])
                ],
                linkerSettings: [
                    .unsafeFlags(["-L\(cmakeOutput)/openssl/lib"]),
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
            dependencies: ["PartoutOS_C"],
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
    case api
    case openVPN
    case wireGuard

    var define: String? {
        switch self {
        case .api: "PARTOUT_API"
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

// MARK: - Core

// MARK: Auto-generated (do not modify)

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.191"
let checksum = "14d87114c8650bf5b474e44ee687078a252eee3ae7b8ea88d88f1510752f7b9d"

enum CoreDeployment: String, RawRepresentable {
    case remoteBinary
    case localSource
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
        ]
    ))
}
package.targets.append(contentsOf: [
    .testTarget(
        name: "PartoutCoreWrapperTests",
        dependencies: ["PartoutCoreWrapper"]
    )
])
