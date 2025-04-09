// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let environment: Environment
//environment = .localDevelopment
//environment = .onlineDevelopment
environment = .production

let binaryFilename = "Partout.xcframework.zip"
let version = "0.99.59"
let checksum = "b46d9c849ef87d3a75b7a1efa514d7837a48234205a86ebbfe7b56b6d49a1da4"

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
                .package(path: "src")
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
            return "Production"
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
                    .product(name: "Partout", package: "src")
                ]
            ))
        }
        targets.append(.testTarget(
            name: "PartoutTests",
            dependencies: [.byName(name: targetName)]
        ))
        return targets
    }
}

let package = Package(
    name: "Partout-Framework",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "Partout-Framework",
            targets: [environment.targetName]
        )
    ],
    dependencies: environment.dependencies,
    targets: environment.targets
)
