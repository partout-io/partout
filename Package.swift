// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation // required for ProcessInfo
import PackageDescription

// MARK: Package

// MARK: Auto-generated (do not modify)

// action-release-binary-package (PartoutCore)
let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.176"
let checksum = "bfdb8c11f1e8924e06c5cfe964e7cb4fab6096eadee30e717dac926d7bd9ced7"

// optional overrides from environment
let env = ProcessInfo.processInfo.environment
let envOS = env["PP_BUILD_OS"]
let envCoreDeployment = env["PP_BUILD_CORE"].map(CoreDeployment.init(rawValue:)) ?? nil
let envWithDocs = env["PP_BUILD_DOCS"] == "1"

// inferred library type
let libraryType: Product.Library.LibraryType? = OS.current == .android ? .dynamic : nil

// MARK: Fine-tuning

// included areas and environment
let areas: Set<Area> = Area.defaultAreas
let coreDeployment = envCoreDeployment ?? .localSource
let coreSourceSHA1 = "dd2b02cc7bdd2ea8899deb3df55e615c41764101"
#if os(Windows)
let vendors: [Vendor] = [.windows, .mbedTLS]
#else
let vendors: [Vendor] = [.openSSL, .mbedTLS]
#endif

// must be false in production (check in CI)
let isDevelopment = true
let isTestingOpenVPNDataPath = false

// the global settings for C targets
let cSettings: [CSetting] = [
    .unsafeFlags([
        "-Wall", "-Wextra"//, "-Werror"
    ])
]

// MARK: Definition

// PartoutCore binaries only on non-Apple
guard OS.current == .apple || ![.remoteBinary, .localBinary].contains(coreDeployment) else {
    fatalError("Core binary only available on Apple platforms")
}

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
                if areas.contains(.encryption) {
                    list.append("_PartoutCryptoImpl_C")
                }
                if areas.contains(.openVPN) {
                    list.append("_PartoutOpenVPNWrapper")
                }
                if areas.contains(.wireGuard) {
                    list.append("_PartoutWireGuardWrapper")
                }
                return list
            }()
        ),
        .target(
            name: "Partout_C",
            dependencies: ["PartoutPortable_C"]
        ),
        .target(
            name: "PartoutInterfaces",
            dependencies: {
                var list: [Target.Dependency] = []

                // always included
                list.append(coreDeployment.dependency)
                list.append("PartoutProviders")
                list.append("PartoutPortable")

                // conditional
                if areas.contains(.api) {
                    list.append("PartoutAPI")
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

package.targets.append(contentsOf: [
    .target(
        name: "PartoutProviders",
        dependencies: [coreDeployment.dependency]
    ),
    .testTarget(
        name: "PartoutProvidersTests",
        dependencies: ["PartoutProviders"],
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
            path: "Sources/PartoutOpenVPN/Wrapper"
        ),
        .target(
            name: "PartoutOpenVPN",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/PartoutOpenVPN/Core"
        ),
        .testTarget(
            name: "PartoutOpenVPNTests",
            dependencies: ["PartoutOpenVPN"],
            path: "Tests/PartoutOpenVPN/Core",
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

    // cross-platform (experimental)
    package.targets.append(contentsOf: [
        .target(
            name: "_PartoutOpenVPN_C",
            dependencies: [
                "_PartoutCryptoImpl_C",
                "_PartoutTLSImpl_C"
            ],
            path: "Sources/PartoutOpenVPN/Cross_C"
        ),
        .target(
            name: "PartoutOpenVPNCross",
            dependencies: {
                var list: [Target.Dependency] = [
                    "PartoutOpenVPN",
                    "_PartoutOpenVPN_C",
                    "PartoutPortable"
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
            path: "Sources/PartoutWireGuard/Wrapper"
        ),
        .target(
            name: "PartoutWireGuard",
            dependencies: ["PartoutCoreWrapper"],
            path: "Sources/PartoutWireGuard/Core"
        ),
        .target(
            name: "_PartoutWireGuard_C",
            path: "Sources/PartoutWireGuard/Cross_C",
            publicHeadersPath: "."
        ),
        .target(
            name: "PartoutWireGuardCross",
            dependencies: [
                "_PartoutVendorsWireGuard",
                "_PartoutWireGuard_C",
                "PartoutWireGuard"
            ],
            path: "Sources/PartoutWireGuard/Cross",
        ),
        .testTarget(
            name: "PartoutWireGuardTests",
            dependencies: ["PartoutWireGuard"],
            path: "Tests/PartoutWireGuard/Core"
        ),
        .testTarget(
            name: "PartoutWireGuardCrossTests",
            dependencies: ["PartoutWireGuardCross"],
            path: "Tests/PartoutWireGuard/Cross"
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

// MARK: - Vendors

// Add cross-platform targets
package.targets.append(contentsOf: [
    .target(
        name: "PartoutPortable",
        dependencies: [
            coreDeployment.dependency,
            "PartoutPortable_C"
        ]
    ),
    .target(
        name: "PartoutPortable_C"
    ),
    .testTarget(
        name: "PartoutPortableTests",
        dependencies: ["PartoutPortable"]
    )
])

// Add vendor implementation targets, for those having one
vendors.forEach {
    if let dependency = $0.dependency(for: .current) {
        package.dependencies.append(dependency)
    }
    if let target = $0.target(for: .current) {
        package.targets.append(target)
    }
}

// MARK: OS

// Add targets relying on OS-specific frameworks
switch OS.current {
case .android:
    break
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
            path: "Sources/Vendors/AppleNE",
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
            name: "_PartoutVendorsAppleTests",
            dependencies: ["_PartoutVendorsApple"],
            path: "Tests/Vendors/Apple"
        ),
        .testTarget(
            name: "_PartoutVendorsAppleNETests",
            dependencies: ["_PartoutVendorsAppleNE"],
            path: "Tests/Vendors/AppleNE",
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
    break
case .windows:
    break
}

// Add vendored encryption if enabled
if areas.contains(.encryption) {

    // The "_PartoutCryptoImpl_C" and "_PartoutTLSImpl_C" targets contain
    // the final implementations of the crypto and TLS routines. It
    // might be a good idea to reuse these names across the manifest
    // rather than copy-paste.

    // Look up the first vendor providing a crypto/TLS implementation
    var foundCrypto = false
    var foundTLS = false
    vendors.forEach {
        if !foundCrypto, let target = $0.cryptoImplTarget(withName: "_PartoutCryptoImpl_C") {
            package.targets.append(target)
            foundCrypto = true
        }
        if !foundTLS, let target = $0.tlsImplTarget(withName: "_PartoutTLSImpl_C") {
            package.targets.append(target)
            foundTLS = true
        }
    }

    assert(foundCrypto, "Missing crypto implementation")
    assert(foundTLS, "Missing TLS implementation")

    package.targets.append(contentsOf: [
        .testTarget(
            name: "PartoutCryptoTests",
            dependencies: [
                "_PartoutCryptoImpl_C",
                "PartoutPortable"
            ],
            exclude: [
                "CryptoPerformanceTests.swift"
            ]
        )
    ])

    // Ad-hoc library targets for local development
    if isDevelopment {
        package.products.append(contentsOf: [
            .library(
                name: "_PartoutCrypto",
                targets: ["_PartoutCryptoImpl_C"]
            ),
            .library(
                name: "_PartoutTLS",
                targets: ["_PartoutTLSImpl_C"]
            )
        ])
    }
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
    case documentation
    case encryption
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
        path: "Sources/Vendors/Core"
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
        path: "Sources/Vendors/Core"
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
            dependencies: ["PartoutCoreWrapper"]
        )
    ])
}

// MARK: -

enum Vendor: String {
    case openSSL = "OpenSSL"
    case mbedTLS = "MbedTLS"
    case windows = "Windows"

    func dependency(for os: OS) -> Package.Dependency? {
        switch self {
        case .openSSL:
            switch os {
            case .apple:
                return .package(url: "https://github.com/passepartoutvpn/openssl-apple", exact: "3.5.200")
            default:
                return nil
            }
        default:
            return nil
        }
    }

    var targetName: String? {
        switch self {
        case .openSSL, .mbedTLS:
            return "_PartoutVendors\(rawValue)"
        default:
            return nil
        }
    }

    func target(for os: OS) -> Target? {
        switch self {
        case .openSSL:
            switch os {
            case .android:
                return .target(
                    name: "_PartoutVendorsOpenSSL",
                    path: "Sources/Vendors/OpenSSL",
                    // use .artifactbundle once supported
                    linkerSettings: [
                        .unsafeFlags(["-Lbin/android-arm64/openssl/lib"]),
                        // WARNING: order matters, ssl then crypto
                        .linkedLibrary("ssl"),
                        .linkedLibrary("crypto")
                    ]
                )
            case .apple:
                return .target(
                    name: "_PartoutVendorsOpenSSL",
                    dependencies: ["openssl-apple"],
                    path: "Sources/Vendors/OpenSSL"
                )
            case .linux:
                return .target(
                    name: "_PartoutVendorsOpenSSL",
                    path: "Sources/Vendors/OpenSSL",
                    // use .artifactbundle once supported
                    linkerSettings: [
                        .unsafeFlags(["-Lbin/linux-aarch64/openssl/lib"]),
                        // WARNING: order matters, ssl then crypto
                        .linkedLibrary("ssl"),
                        .linkedLibrary("crypto")
                    ]
                )
            case .windows:
                fatalError("OpenSSL not supported on Windows")
            }
        case .mbedTLS:
            return .target(
                name: "_PartoutVendorsMbedTLS",
                path: "Sources/Vendors/MbedTLS",
                // use .artifactbundle once supported
                linkerSettings: [
                    .unsafeFlags(["-Lbin/darwin-arm64/mbedtls/lib"]),
                    // WARNING: order matters, ssl then crypto
                    .linkedLibrary("mbedcrypto"),
                    .linkedLibrary("mbedtls"),
                    .linkedLibrary("mbedx509")
                ]
            )
        case .windows:
            guard os == .windows else {
                fatalError("Windows vendor used outside of Windows OS")
            }
            return nil
        }
    }
}

extension Vendor {
    func cryptoImplTarget(withName name: String) -> Target? {
        switch self {
        case .openSSL:
            var dependencies: [Target.Dependency] = ["PartoutPortable_C"]
            if let targetName {
                dependencies.append(.target(name: targetName))
            }
            let cSettings: [CSetting]
            switch OS.current {
            case .android:
                cSettings = [
                    .unsafeFlags(["-Ibin/android-arm64/openssl/include"])
                ]
            case .linux:
                cSettings = [
                    .unsafeFlags(["-Ibin/linux-aarch64/openssl/include"])
                ]
            default:
                cSettings = []
            }
            return .target(
                name: name,
                dependencies: dependencies,
                path: "Sources/Impl/Crypto\(rawValue)_C",
                cSettings: cSettings
            )
        case .windows:
            return nil
        case .mbedTLS:
            return nil
        }
    }

    func tlsImplTarget(withName name: String) -> Target? {
        switch self {
        case .openSSL:
            var dependencies: [Target.Dependency] = ["PartoutPortable_C"]
            if let targetName {
                dependencies.append(.target(name: targetName))
            }
            let cSettings: [CSetting]
            switch OS.current {
            case .android:
                cSettings = [
                    .unsafeFlags(["-Ibin/android-arm64/openssl/include"])
                ]
            case .linux:
                cSettings = [
                    .unsafeFlags(["-Ibin/linux-aarch64/openssl/include"])
                ]
            default:
                cSettings = []
            }
            return .target(
                name: name,
                dependencies: dependencies,
                path: "Sources/Impl/TLS\(rawValue)_C",
                cSettings: cSettings
            )
        case .windows:
            return nil
        case .mbedTLS:
            return nil
        }
    }
}
