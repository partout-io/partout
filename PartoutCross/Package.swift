// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let package = Package(
    name: "PartoutCross",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
)

let areas: Set<CrossArea> = Set(CrossArea.allCases)

// the OpenVPN crypto mode (ObjC -> C)
let openVPNCryptoMode: OpenVPNCryptoMode = .fromEnvironment(
    "OPENVPN_CRYPTO_MODE",
    fallback: .wrapped
)

enum CrossArea: CaseIterable {
    case openvpn

    case wireguard
}

// MARK: - OpenVPN

if areas.contains(.openvpn) {

    // the global settings for C targets
    let cSettings: [CSetting] = [
        .unsafeFlags([
            "-Wall", "-Wextra"//, "-Werror"
        ])
    ]

    let wrappedSwiftSettings: [SwiftSetting] = {
        var defines: [String] = []
        switch openVPNCryptoMode {
        case .wrappedNative, .native:
            defines.append("OPENVPN_WRAPPED_NATIVE")
        default:
            break
        }
        return defines.map {
            .define($0)
        }
    }()

    // MARK: OpenVPN (common)

    let cryptoUmbrella = "_PartoutCryptoOpenSSL_Cross"
    let mainUmbrella = "_PartoutOpenVPNOpenSSL_Cross"

    package.products.append(contentsOf: [
        .library(
            name: cryptoUmbrella,
            targets: [cryptoUmbrella]
        ),
        .library(
            name: "_PartoutCryptoOpenSSL_C",
            targets: ["_PartoutCryptoOpenSSL_C"]
        )
    ])

    // TODO: ###, experimental, still local, try single repo with multiplatform slices
    let opensslPackage: String
#if os(Windows)
    opensslPackage = "openssl-windows"
    package.dependencies.append(contentsOf: [
        .package(path: "../../\(opensslPackage)")
    ])
#elseif os(Linux)
    opensslPackage = "openssl-linux"
    package.dependencies.append(contentsOf: [
        .package(path: "../../\(opensslPackage)")
    ])
#else
    opensslPackage = "openssl-apple"
    package.dependencies.append(contentsOf: [
        .package(url: "https://github.com/passepartoutvpn/openssl-apple", from: "3.4.200")
    ])
#endif

    if openVPNCryptoMode != .bridgedCrypto {
        package.dependencies.append(contentsOf: [
            .package(path: "..") // "partout"
        ])
        package.products.append(contentsOf: [
            .library(
                name: mainUmbrella,
                targets: [mainUmbrella]
            ),
            .library(
                name: "_PartoutOpenVPNOpenSSL_C",
                targets: ["_PartoutOpenVPNOpenSSL_C"]
            ),
        ])
        package.targets.append(contentsOf: [
            .target(
                name: "_PartoutOpenVPNOpenSSL_C",
                dependencies: ["_PartoutCryptoOpenSSL_C"],
                path: "Sources/OpenVPN/OpenVPNOpenSSL_C",
                cSettings: cSettings
            ),
            .testTarget(
                name: "_PartoutOpenVPNOpenSSL_CrossTests",
                dependencies: [.target(name: mainUmbrella)],
                path: "Tests/OpenVPN/OpenVPNOpenSSL"
            )
        ])
    }

    package.targets.append(contentsOf: [
        .testTarget(
            name: "_PartoutCryptoOpenSSL_CrossTests",
            dependencies: [cryptoUmbrella.asTargetDependency],
            path: "Tests/OpenVPN/CryptoOpenSSL"
        )
    ])

    // MARK: OpenVPN (specific)

    switch openVPNCryptoMode {
    case .bridgedCrypto:
        package.products.append(contentsOf: [
            .library(
                name: "_PartoutCryptoOpenSSL_ObjC_Bridged",
                targets: ["_PartoutCryptoOpenSSL_ObjC_Bridged"]
            )
        ])
        package.targets.append(contentsOf: [
            .target(
                name: cryptoUmbrella,
                dependencies: ["_PartoutCryptoOpenSSL_ObjC_Bridged"],
                path: "Sources/OpenVPN/CryptoOpenSSL",
                exclude: ["Native"]
            ),
            .target(
                name: "_PartoutCryptoOpenSSL_C",
                dependencies: [opensslPackage.asProductDependency],
                path: "Sources/OpenVPN/CryptoOpenSSL_C",
                cSettings: cSettings
            ),
            .target(
                name: "_PartoutCryptoOpenSSL_ObjC_Bridged",
                dependencies: ["_PartoutCryptoOpenSSL_C"],
                path: "Sources/OpenVPN/CryptoOpenSSL_ObjC_Bridged"
            )
        ])

    case .wrapped, .wrappedNative:
        package.targets.append(contentsOf: [
            .target(
                name: cryptoUmbrella,
                dependencies: ["_PartoutCryptoOpenSSL_C"],
                path: "Sources/OpenVPN/CryptoOpenSSL",
                exclude: ["Bridged"]
            ),
            .target(
                name: "_PartoutCryptoOpenSSL_C",
                dependencies: [opensslPackage.asProductDependency],
                path: "Sources/OpenVPN/CryptoOpenSSL_C",
                cSettings: cSettings
            ),
            .target(
                name: mainUmbrella,
                dependencies: [
                    cryptoUmbrella.asTargetDependency,
                    "_PartoutOpenVPNOpenSSL_C",
                    .product(name: "_PartoutOpenVPNCore", package: "partout"),
                    .product(name: "_PartoutOpenVPNOpenSSL_ObjC", package: "partout")
                ],
                path: "Sources/OpenVPN/OpenVPNOpenSSL",
                exclude: ["TODO"],
                swiftSettings: wrappedSwiftSettings
            )
        ])

    case .native:
        package.targets.append(contentsOf: [
            .target(
                name: cryptoUmbrella,
                dependencies: ["_PartoutCryptoOpenSSL_C"],
                path: "Sources/OpenVPN/CryptoOpenSSL",
                exclude: ["Bridged"]
            ),
            .target(
                name: "_PartoutCryptoOpenSSL_C",
                dependencies: [opensslPackage.asProductDependency],
                path: "Sources/OpenVPN/CryptoOpenSSL_C",
                cSettings: cSettings
            ),
            .target(
                name: mainUmbrella,
                dependencies: [
                    cryptoUmbrella.asTargetDependency,
                    "_PartoutOpenVPNOpenSSL_C",
                    .product(name: "_PartoutOpenVPNCore", package: "partout")
                ],
                path: "Sources/OpenVPN/OpenVPNOpenSSL",
                exclude: ["Internal/Legacy", "TODO"],
                swiftSettings: wrappedSwiftSettings
            )
        ])
    }
}

enum OpenVPNCryptoMode: Int {
    case bridgedCrypto = 1

    case wrapped = 2

    case wrappedNative = 3

    case native = 4

    static func fromEnvironment(_ key: String, fallback: Self) -> Self {
        guard let envModeString = ProcessInfo.processInfo.environment[key],
              let envModeInt = Int(envModeString),
              let envMode = Self(rawValue: envModeInt) else {
            return fallback
        }
        return envMode
    }
}

// MARK: - WireGuard

// MARK: -

private extension String {
    var asTargetDependency: Target.Dependency {
        .target(name: self)
    }

    var asProductDependency: Target.Dependency {
        .product(name: self, package: self)
    }
}
