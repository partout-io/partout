// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let cryptoUmbrella = "_PartoutCryptoOpenSSL_Cross"
let mainUmbrella = "_PartoutOpenVPNOpenSSL_Cross"

let package = Package(
    name: "PartoutCross",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: cryptoUmbrella,
            targets: [cryptoUmbrella]
        ),
        .library(
            name: "_PartoutCryptoOpenSSL_C",
            targets: ["_PartoutCryptoOpenSSL_C"]
        )
    ]
)

// the OpenVPN crypto mode (ObjC -> C)
let cryptoMode: CryptoMode = .fromEnvironment(
    "OPENVPN_CRYPTO_MODE",
    fallback: .bridgedCrypto
)

// the global settings for C targets
let cSettings: [CSetting] = [
    .unsafeFlags([
        "-Wall", "-Wextra"//, "-Werror"
    ])
]

let wrappedSwiftSettings: [SwiftSetting] = {
    var defines: [String] = ["OPENVPN_WRAPPED"]
    switch cryptoMode {
    case .wrappedNative, .native:
        defines.append("OPENVPN_WRAPPED_NATIVE")
    default:
        break
    }
    return defines.map {
        .define($0)
    }
}()

// MARK: Targets (common)

package.dependencies.append(contentsOf: [
    .package(url: "https://github.com/passepartoutvpn/openssl-apple", from: "3.4.200")
])

if cryptoMode != .bridgedCrypto {
    package.dependencies.append(contentsOf: [
        .package(path: ".."), // "partout"
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
        dependencies: [.target(name: cryptoUmbrella)],
        path: "Tests/OpenVPN/CryptoOpenSSL"
    )
])

// MARK: Targets (specific)

switch cryptoMode {
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
            dependencies: [
                "_PartoutCryptoOpenSSL_C",
                "_PartoutCryptoOpenSSL_ObjC_Bridged"
            ],
            path: "Sources/OpenVPN/CryptoOpenSSL",
            exclude: ["Native"]
        ),
        .target(
            name: "_PartoutCryptoOpenSSL_C",
            dependencies: ["openssl-apple"],
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
            dependencies: ["openssl-apple"],
            path: "Sources/OpenVPN/CryptoOpenSSL_C",
            cSettings: cSettings
        ),
        .target(
            name: mainUmbrella,
            dependencies: [
                "_PartoutOpenVPNOpenSSL_C",
                .product(name: "_PartoutOpenVPN", package: "partout"),
                .product(name: "_PartoutOpenVPNOpenSSL_ObjC", package: "partout")
            ],
            path: "Sources/OpenVPN/OpenVPNOpenSSL",
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
            dependencies: ["openssl-apple"],
            path: "Sources/OpenVPN/CryptoOpenSSL_C",
            cSettings: cSettings
        ),
        .target(
            name: mainUmbrella,
            dependencies: [
                "_PartoutOpenVPNOpenSSL_C",
                .product(name: "_PartoutOpenVPN", package: "partout")
            ],
            path: "Sources/OpenVPN/OpenVPNOpenSSL",
            exclude: ["Legacy"],
            swiftSettings: wrappedSwiftSettings
        )
    ])
}

// MARK: Structures

enum CryptoMode: Int {
    case bridgedCrypto = 1

    case wrapped = 2

    case wrappedNative = 3

    case native = 4

    static func fromEnvironment(_ key: String, fallback: Self) -> Self {
        guard let envModeString = ProcessInfo.processInfo.environment[key],
              let envModeInt = Int(envModeString),
              let envMode = CryptoMode(rawValue: envModeInt) else {
            return fallback
        }
        return envMode
    }
}
