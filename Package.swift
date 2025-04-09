// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let environment: Environment
//environment = .localDevelopment
//environment = .onlineDevelopment
environment = .production

let binaryFilename = "Partout.xcframework.zip"
let version = "0.99.55"
let checksum = "19bc43b75e5801519f964eb2582fbabc9861d7769cc9548958be377adecd55df"

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
