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
let openSSLVersion: Version = "3.5.500"
let wgGoVersion: Version = "0.0.2025063103"
let cmakeOutput = envCMakeOutput ?? ".bin/windows-arm64"
let useFoundationCompatibility: FoundationCompatibility = .off
// let useFoundationCompatibility: FoundationCompatibility = OS.current != .apple ? .on : .off

// MARK: - Package

// Build dynamic library on Android
var libraryType: Product.Library.LibraryType? = nil
var staticLibPrefix = ""
switch OS.current {
case .android, .linux:
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
            } + useFoundationCompatibility.swiftSettings
        ),
        .target(
            name: "PartoutABI_C"
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: ["Partout"],
            exclude: useFoundationCompatibility.partoutTestsExclude,
            swiftSettings: areas.compactMap(\.define).map {
                .define($0)
            } + useFoundationCompatibility.swiftSettings
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
            "MiniFoundation",
            "PartoutABI_C",
            "PartoutCore_C"
        ],
        swiftSettings: useFoundationCompatibility.swiftSettings
    ),
    .target(
        name: "PartoutCore_C",
        cSettings: globalCSettings + {
            if OS.current == .windows {
                return [
                    .unsafeFlags(["-I\(cmakeOutput)/../../vendors/wintun"])
                ]
            }
            return []
        }()
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
        }(),
        swiftSettings: useFoundationCompatibility.swiftSettings
    ),
    .testTarget(
        name: "PartoutCoreTests",
        dependencies: ["PartoutCore"],
        exclude: useFoundationCompatibility.coreTestsExclude,
        swiftSettings: useFoundationCompatibility.swiftSettings
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
if useFoundationCompatibility.supportsPartoutd {
    package.targets.append(
        .executableTarget(
            name: "partoutd",
            dependencies: ["Partout"],
            path: "Executables/partoutd"
        )
    )
}

// MARK: OpenVPN

// OpenVPN requires Crypto/TLS wrappers
if areas.contains(.openVPN), cryptoMode != nil {
    package.products.append(
        .library(
            name: "PartoutOpenVPN",
            targets: ["PartoutOpenVPN"]
        )
    )
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutOpenVPN_C",
            dependencies: ["_PartoutCryptoImpl_C"],
            cSettings: globalCSettings
        ),
        .target(
            name: "PartoutOpenVPN",
            dependencies: [
                "PartoutOpenVPN_C",
                "PartoutOS"
            ]
        ),
        .testTarget(
            name: "PartoutOpenVPNTests",
            dependencies: ["PartoutOpenVPN"],
            exclude: useFoundationCompatibility.openVPNTestsExclude + ["DataPathPerformanceTests.swift"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: useFoundationCompatibility.swiftSettings
        )
    ])
}

// MARK: WireGuard

if areas.contains(.wireGuard) {
    switch OS.current {
    case .apple:
        // Require static wg-go backend
        package.dependencies.append(
            .package(url: "https://github.com/partout-io/wg-go-apple", from: wgGoVersion)
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
            ]
        ),
        .testTarget(
            name: "PartoutWireGuardTests",
            dependencies: ["PartoutWireGuard"],
            exclude: useFoundationCompatibility.wireGuardTestsExclude
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
            .package(url: "https://github.com/partout-io/openssl-apple", from: openSSLVersion)
        )
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutCryptoImpl_C",
                dependencies: [
                    "openssl-apple",
                    "PartoutCore_C"
                ],
                path: "Sources/PartoutCrypto/OpenSSL_C"
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

// MARK: - MiniFoundation

package.products.append(
    .library(
        name: "MiniFoundation",
        type: .static,
        targets: ["MiniFoundation"]
    )
)
package.targets.append(contentsOf: [
    .target(
        name: "MiniFoundation",
        dependencies: [
            useFoundationCompatibility == .on ?
                .target(name: "MiniFoundationCompat") :
                .target(name: "MiniFoundationNative")
        ],
        swiftSettings: useFoundationCompatibility.swiftSettings
    ),
    .target(
        name: "MiniFoundationCore",
        dependencies: ["MiniFoundationCore_C"]
    ),
    .target(
        name: "MiniFoundationCore_C"
    ),
    .target(
        name: "MiniFoundationCompat",
        dependencies: ["MiniFoundationCore"]
    ),
    .executableTarget(
        name: "MiniFoundationExample",
        dependencies: ["MiniFoundation"]
    ),
    .testTarget(
        name: "MiniFoundationTests",
        dependencies: ["MiniFoundation"],
        swiftSettings: useFoundationCompatibility.swiftSettings
    )
])

if useFoundationCompatibility == .off {
    package.targets.append(
        .target(
            name: "MiniFoundationNative",
            dependencies: ["MiniFoundationCore"]
        )
    )
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

enum FoundationCompatibility {
    case off
    case on

    var partoutTestsExclude: [String] {
        switch self {
        case .off: []
        case .on: ["RegistryTests.swift"]
        }
    }

    var coreTestsExclude: [String] {
        switch self {
        case .off: []
        case .on: [
            "MessageHandlerTests.swift",
            "PartoutErrorTests.swift",
            "ProfileCodingTests.swift",
            "SecureDataTests.swift",
            "SensitiveEncoderTests.swift"
        ]
        }
    }

    var openVPNTestsExclude: [String] {
        switch self {
        case .off: []
        case .on: [
            "JSONTests.swift",
            "KeyDecrypterTests.swift",
            "OpenVPNParserTests.swift",
            "TLSTests.swift"
        ]
        }
    }

    var wireGuardTestsExclude: [String] {
        switch self {
        case .off: []
        case .on: [
            "BackendTests.swift"
        ]
        }
    }

    var swiftSettings: [SwiftSetting] {
        switch self {
        case .off: []
        case .on: [.define("MINI_FOUNDATION_COMPAT")]
        }
    }

    var supportsPartoutd: Bool {
        self == .off
    }
}
