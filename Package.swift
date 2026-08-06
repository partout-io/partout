// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Foundation is required by ProcessInfo
import Foundation
import PackageDescription

// MARK: Environment

let envDocs = ProcessInfo.processInfo.environment["PP_BUILD_DOCS"] == "1"

// MARK: Configuration

let vendorsConfiguration = VendorsConfiguration(
    location: .local("../../prebuilts/artifacts/"),
//    location: .remote(
//        "https://github.com/partout-io/prebuilts/releases/download",
//        version: "0.5.2"
//    ),
    checksums: [
        .openSSL: "dc092eb9950083492bd341834771a996213457119e7427f244dbfbe899cd143f",
        .mbedTLS: "084d1e16f41bcfa683082ada4601f887cb98608bf4dd91164ba8655634b11013",
        .wgGo: "5ce6457721b49a0221e2465ca8eb94b9e5ce40c208a53a5192737cb0061d6a0b"
    ]
)

let cryptoLibraries: [CryptoLibrary] = [.openSSL]
let useFoundationCompatibility: FoundationCompatibility = .off

// Exclude OpenVPN if no crypto libraries
let areas = Area.allCases.filter {
    $0 != .openVPN || !cryptoLibraries.isEmpty
}

// MARK: - Package

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
            targets: ["Partout"]
        ),
        .library(
            name: "Partout_C",
            targets: ["Partout_C"]
        ),
        .library(
            name: "PartoutRuntime",
            targets: ["PartoutRuntime"]
        )
    ],
    targets: [
        .target(
            name: "Partout",
            dependencies: {
                // These are always included
                var list: [Target.Dependency] = [
                    "Partout_C",
                    "PartoutCrypto_C",
                    "PartoutCore",
                    "PartoutOS"
                ]
                if areas.contains(.openVPN) {
                    list.append("PartoutOpenVPN")
                }
                if areas.contains(.wireGuard) {
                    list.append("PartoutWireGuard")
                }
                return list
            }(),
            swiftSettings: areas.swiftSettings + useFoundationCompatibility.swiftSettings
        ),
        .target(
            name: "Partout_C",
            dependencies: {
                var list: [Target.Dependency] = [
                    "PartoutCrypto_C",
                    "PartoutCore_C"
                ]
                if areas.contains(.openVPN) {
                    list.append("PartoutOpenVPN_C")
                }
                if areas.contains(.wireGuard) {
                    list.append("PartoutWireGuard_C")
                }
                return list
            }(),
            cSettings: globalCSettings + cryptoLibraries.cSettings + {
                var list: [CSetting] = []
                if areas.contains(.openVPN) {
                    list.append(.define("PARTOUT_OPENVPN"))
                }
                if areas.contains(.wireGuard) {
                    list.append(.define("PARTOUT_WIREGUARD"))
                }
                return list
            }()
        ),
        .target(
            name: "PartoutRuntime",
            dependencies: ["Partout"]
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
        cSettings: globalCSettings
    ),
    .target(
        name: "PartoutOS",
        dependencies: ["PartoutCore"],
        exclude: {
            var list: [String] = []
#if swift(>=6.0)
            list.append(contentsOf: [
                "AppleNE/Connection/NEUDPSocket.swift",
                "AppleNE/Connection/NETCPSocket.swift",
                "AppleNE/Extensions/NWUDPSessionState+Description.swift",
                "AppleNE/Extensions/NWTCPConnectionState+Description.swift",
                "AppleNE/Connection/SafeValueObserver.swift"
            ])
#endif
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
#if swift(>=6.0)
            list.append("AppleNE/ValueObserverTests.swift")
#endif
            return list
        }()
    )
])

// MARK: OpenVPN

// OpenVPN requires Crypto/TLS wrappers
if areas.contains(.openVPN) {
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
            ],
            swiftSettings: cryptoLibraries.swiftSettings
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
    package.targets.append(contentsOf: [
        vendorsConfiguration.target(for: .wgGo),
        .target(
            name: "PartoutWireGuard_C",
            dependencies: [
                "PartoutCore_C",
                "wg-go"
            ]
        )
    ])
    package.targets.append(contentsOf: [
        .target(
            name: "PartoutWireGuard",
            dependencies: [
                "PartoutCore",
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

var cryptoDependencies: [Target.Dependency] = ["PartoutCore_C"]

for mode in cryptoLibraries {
    switch mode {
    case .openSSL:
        // OpenSSL-based crypto/TLS implementations
        package.targets.append(
            vendorsConfiguration.target(for: .openSSL)
        )
        cryptoDependencies.append("openssl")
    case .mbedTLS:
        // Crypto with OS routines, TLS with MbedTLS
        package.targets.append(
            vendorsConfiguration.target(for: .mbedTLS)
        )
        cryptoDependencies.append("mbedtls")
    }
}

// Include concrete crypto targets if supported
package.targets.append(
    .target(
        name: "PartoutCrypto_C",
        dependencies: cryptoDependencies,
        exclude: {
            // Only Darwin provides the native crypto implementation.
            var list: [String] = []
            if !cryptoLibraries.contains(.openSSL) {
                list.append("crypto_openssl.c")
            }
            if !cryptoLibraries.contains(.mbedTLS) {
                list.append("crypto_mbedtls.c")
                list.append("crypto_darwin.c")
            }
            list.append(contentsOf: [
                "crypto_linux.c",
                "crypto_windows.c"
            ])
            return list
        }(),
        cSettings: globalCSettings
    )
)
package.products.append(
    .library(
        name: "PartoutCrypto",
        targets: ["PartoutCrypto_C"]
    )
)
if !cryptoLibraries.isEmpty {
    package.targets.append(contentsOf: [
        .testTarget(
            name: "PartoutCryptoTests",
            dependencies: [
                "PartoutCrypto_C",
                "PartoutOS"
            ],
            exclude: [
                "CryptoPerformanceTests.swift"
            ],
            swiftSettings: cryptoLibraries.swiftSettings
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

protocol Definable {
    var define: String { get }
}

enum Area: Definable, CaseIterable {
    case openVPN
    case wireGuard

    var define: String {
        switch self {
        case .openVPN: "PARTOUT_OPENVPN"
        case .wireGuard: "PARTOUT_WIREGUARD"
        }
    }
}

enum CryptoLibrary: Definable {
    case openSSL
    case mbedTLS

    var define: String {
        switch self {
        case .openSSL: "PARTOUT_CRYPTO_OPENSSL"
        case .mbedTLS: "PARTOUT_CRYPTO_MBEDTLS"
        }
    }
}

extension Collection where Element: Definable {
    var cSettings: [CSetting] {
        map {
            .define($0.define)
        }
    }

    var swiftSettings: [SwiftSetting] {
        map {
            .define($0.define)
        }
    }
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

enum Vendor: String {
    case openSSL = "openssl"
    case mbedTLS = "mbedtls"
    case wgGo = "wg-go"
}

struct VendorsConfiguration {
    enum Location {
        case local(String)
        case remote(String, version: String)
    }

    private let location: Location
    private let checksums: [Vendor: String]

    init(location: Location, checksums: [Vendor: String]) {
        self.location = location
        self.checksums = checksums
    }

    func target(for vendor: Vendor) -> Target {
        switch location {
        case .local(let path):
            return .binaryTarget(
                name: vendor.rawValue,
                path: "\(path)/\(vendor.rawValue).xcframework.zip"
            )
        case .remote(let url, let version):
            return .binaryTarget(
                name: vendor.rawValue,
                url: "\(url)/\(version)/\(vendor.rawValue).xcframework.zip",
                checksum: checksums[vendor]!
            )
        }
    }
}
