// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let environment: Environment
// environment = .localDevelopment
// environment = .onlineDevelopment
environment = .production

let binaryFilename = "PartoutCore.xcframework.zip"
let version = "0.99.70"
let checksum = "82105e815325c40e560f48f7e5b61744b55fed6351196382c24f1b991edbc475"

enum Environment {
    case localDevelopment

    case onlineDevelopment

    case production

    var dependencies: [Package.Dependency] {
        switch self {
        case .localDevelopment:
            return []
        case .onlineDevelopment:
            return []
        case .production:
            return [
                .package(path: "../CoreSource")
            ]
        }
    }

    var targetName: String {
        switch self {
        case .localDevelopment:
            return "LocalDevelopment"
        case .onlineDevelopment:
            return "OnlineDevelopment"
        case .production:
            return "PartoutCore"
        }
    }

    var targets: [Target] {
        var targets: [Target] = []
        switch self {
        case .localDevelopment:
            targets.append(.binaryTarget(
                name: targetName,
                path: binaryFilename
            ))
        case .onlineDevelopment:
            targets.append(.binaryTarget(
                name: targetName,
                url: "https://github.com/passepartoutvpn/partout/releases/download/\(version)/\(binaryFilename)",
                checksum: checksum
            ))
        case .production:
            targets.append(.target(
                name: targetName,
                dependencies: [
                    .product(name: "PartoutCoreSource", package: "CoreSource")
                ]
            ))
        }
        targets.append(.testTarget(
            name: "PartoutCoreTests",
            dependencies: [.byName(name: targetName)]
        ))
        return targets
    }
}

let package = Package(
    name: "PartoutCoreWrapper",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "PartoutCore",
            targets: [environment.targetName]
        )
    ],
    dependencies: environment.dependencies,
    targets: environment.targets
)
