// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let localNativeURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("PartoutNative.xcframework")

let nativeTarget: PartoutNativeTarget
if FileManager.default.fileExists(atPath: localNativeURL.path) {
    nativeTarget = .local
} else {
    nativeTarget = .remote("0.161.4", checksum: "8c4369004d53e71beb9cd09981213a469032943c5c783e0bdb43b74681fd01cc")
}

let partoutNative: Target = .partoutNative(nativeTarget)

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
            targets: ["PartoutRuntime"]
        ),
        .library(
            name: "PartoutCore",
            targets: ["PartoutCore"]
        ),
        .library(
            name: "PartoutCore_C",
            targets: ["PartoutCore_C"]
        )
    ],
    targets: [
        partoutNative,
        .target(
            name: "PartoutCore",
            dependencies: ["PartoutCore_C"],
            path: "cross/apple/Sources/PartoutCore"
        ),
        .target(
            name: "PartoutCore_C",
            path: "cross/apple/Sources/PartoutCore_C"
        ),
        .target(
            name: "PartoutRuntime",
            dependencies: [
                "PartoutCore",
                "PartoutNative"
            ],
            path: "cross/apple/Sources/PartoutRuntime"
        ),
        .testTarget(
            name: "PartoutTests",
            dependencies: [
                "PartoutCore",
                "PartoutRuntime"
            ],
            path: "cross/apple/Tests/PartoutTests"
        )
    ],
    swiftLanguageModes: [.v6]
)

enum PartoutNativeTarget {
    case local
    case remote(_ version: String, checksum: String)
}

extension Target {
    static func partoutNative(_ target: PartoutNativeTarget) -> Target {
        let name = "PartoutNative"
        switch target {
        case .local:
            return .binaryTarget(
                name: name,
                path: "\(name).xcframework"
            )
        case .remote(let version, let checksum):
            return .binaryTarget(
                name: name,
                url: "https://github.com/partout-io/partout/releases/download/\(version)/\(name).xcframework.zip",
                checksum: checksum
            )
        }
    }
}
