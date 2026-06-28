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

let areas = Area.allCases
let cryptoModes: [CryptoMode] = [.openSSL, .native]
let openSSLVersion: Version = "3.6.300" // 3.6.2
let wgGoVersion: Version = "0.0.20260530"
// Local CMake output is only required for generated wg-go and wintun artifacts.
let cmakeOutput = envCMakeOutput ?? "bin/darwin-arm64"
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
        "-W", "-Wall", "-Wextra", "-pedantic", "-Werror",
        "-Wno-nullability-extension"
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
        ),
        .library(
            name: "Partout_C",
            targets: ["Partout_C"]
        )
    ],
    targets: [
        .target(
            name: "Partout",
            dependencies: {
                // These are always included
                var list: [Target.Dependency] = [
                    "Partout_C",
                    "PartoutCore",
                    "PartoutOS"
                ]
                if !cryptoModes.isEmpty {
                    list.append("PartoutCrypto_C")
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
            name: "Partout_C",
            dependencies: {
                var list: [Target.Dependency] = [
                    "PartoutCore_C"
                ]
                if !cryptoModes.isEmpty {
                    list.append("PartoutCrypto_C")
                    if areas.contains(.openVPN) {
                        list.append("PartoutOpenVPN_C")
                    }
                }
                if areas.contains(.wireGuard) {
                    list.append("PartoutWireGuard_C")
                    list.append("PartoutWireGuardBackend_C")
                }
                return list
            }(),
            cSettings: globalCSettings + {
                var list: [CSetting] = []
                if areas.contains(.openVPN), !cryptoModes.isEmpty {
                    list.append(.define("PARTOUT_OPENVPN"))
                }
                if areas.contains(.wireGuard) {
                    list.append(.define("PARTOUT_WIREGUARD"))
                }
                return list
            }()
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
            "PartoutCore_C"
        ],
        swiftSettings: useFoundationCompatibility.swiftSettings
    ),
    .target(
        name: "PartoutCore_C",
        cSettings: globalCSettings + {
            var list: [CSetting] = []
            if OS.current == .windows {
                list.append(.unsafeFlags([
                    "-I\(cmakeOutput)/wintun"
                ]))
            }
            return list
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

// MARK: OpenVPN

// OpenVPN requires Crypto/TLS wrappers
if areas.contains(.openVPN), !cryptoModes.isEmpty {
    package.products.append(
        .library(
            name: "PartoutOpenVPN",
            targets: ["PartoutOpenVPN"]
        )
    )
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutOpenVPN_C",
            dependencies: ["PartoutCrypto_C"],
            cSettings: globalCSettings
        ),
        .target(
            name: "PartoutOpenVPN",
            dependencies: [
                "PartoutCore",
                "PartoutOpenVPN_C"
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
    package.products.append(
        .library(
            name: "PartoutWireGuard",
            targets: ["PartoutWireGuard"]
        )
    )
    switch OS.current {
    case .apple:
        // Require static wg-go backend
        package.dependencies.append(
            .package(url: "https://github.com/partout-io/wg-go-apple", exact: wgGoVersion)
        )
        package.targets.append(
            .target(
                name: "PartoutWireGuardBackend_C",
                dependencies: [
                    "PartoutWireGuard_C",
                    "wg-go-apple"
                ]
            )
        )
    default:
        // Load wg-go backend dynamically
        package.targets.append(
            .target(
                name: "PartoutWireGuardBackend_C",
                dependencies: ["PartoutWireGuard_C"],
                cSettings: globalCSettings + [
                    .unsafeFlags(["-I\(cmakeOutput)/wg-go/include"])
                ],
                linkerSettings: [
                    .unsafeFlags(["-L\(cmakeOutput)/wg-go/lib"]),
                    .linkedLibrary("\(staticLibPrefix)wg-go")
                ]
            )
        )
    }
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutWireGuard",
            dependencies: [
                "PartoutCore",
                "PartoutWireGuard_C",
                "PartoutWireGuardBackend_C"
            ]
        ),
        .target(
            name: "PartoutWireGuard_C",
            dependencies: ["PartoutCore_C"]
        ),
        .testTarget(
            name: "PartoutWireGuardTests",
            dependencies: ["PartoutWireGuard"],
            exclude: useFoundationCompatibility.wireGuardTestsExclude
        )
    ])
}

// MARK: - Crypto

var cryptoDependencies: [Target.Dependency] = ["PartoutCore_C"]

for mode in cryptoModes {
    switch mode {
    case .openSSL:
        // OpenSSL-based crypto/TLS implementations
        switch OS.current {
        case .apple:
            package.dependencies.append(
                .package(url: "https://github.com/partout-io/openssl-apple", from: openSSLVersion)
            )
            cryptoDependencies.append("openssl-apple")
        default:
            package.targets.append(
                .systemLibrary(
                    name: "COpenSSL",
                    path: "Sources/SystemLibraries/COpenSSL",
                    pkgConfig: "openssl",
                    providers: [
                        .brew(["openssl@3"]),
                        .apt(["libssl-dev"])
                    ]
                )
            )
            cryptoDependencies.append("COpenSSL")
        }
    case .native:
        // Crypto with OS routines, TLS with MbedTLS
        package.targets.append(
            .systemLibrary(
                name: "CMbedTLS",
                path: "Sources/SystemLibraries/CMbedTLS",
                pkgConfig: "mbedtls",
                providers: [
                    .brew(["mbedtls"]),
                    .apt(["libmbedtls-dev"])
                ]
            )
        )
        cryptoDependencies.append("CMbedTLS")
    }
}

// Include concrete crypto targets if supported
if !cryptoModes.isEmpty {
    package.targets.append(
        .target(
            name: "PartoutCrypto_C",
            dependencies: cryptoDependencies,
            exclude: {
                // Pick current OS by removing it from exclusions
                var list = Set(OS.nativeCryptoSources)
                list.remove(OS.current.nativeCryptoSource)
                return list.map { "native/\($0.rawValue)" }
            }(),
            cSettings: globalCSettings,
            linkerSettings: {
                var list: [LinkerSetting] = []
                if cryptoModes.contains(.native) {
                    list.append(.linkedLibrary("mbedx509"))
                    list.append(.linkedLibrary("mbedcrypto"))
                }
                return list
            }()
        )
    )
    package.products.append(
        .library(
            name: "PartoutCrypto",
            targets: ["PartoutCrypto_C"]
        )
    )
    package.targets.append(contentsOf: [
        .testTarget(
            name: "PartoutCryptoTests",
            dependencies: [
                "PartoutCrypto_C",
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
        dependencies: ["MiniFoundation_C"],
        swiftSettings: useFoundationCompatibility.swiftSettings
    ),
    .target(
        name: "MiniFoundation_C"
    ),
    .testTarget(
        name: "MiniFoundationTests",
        dependencies: ["MiniFoundation"],
        resources: [
            .process("Resources")
        ],
        swiftSettings: useFoundationCompatibility.swiftSettings
    )
])

// MARK: - Configuration structures

enum Area: CaseIterable {
    case openVPN
    case wireGuard

    var define: String? {
        switch self {
        case .openVPN: "PARTOUT_OPENVPN"
        case .wireGuard: "PARTOUT_WIREGUARD"
        }
    }
}

enum OS: String, CaseIterable {
    case android
    case apple = "darwin"
    case linux
    case windows

    static let nativeCryptoSources: Set<OS> = [.apple, .linux, .windows]

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

    var nativeCryptoSource: OS {
        switch self {
        case .android: .linux
        default: self
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
        case .on: [.define("MINIF_COMPAT")]
        }
    }
}
