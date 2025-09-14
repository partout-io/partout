// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let dependency: Target.Dependency = .product(name: "Partout", package: "partout")

let package = Package(
    name: "PartoutExamples",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "test-abi",
            dependencies: [dependency]
        ),
        .executableTarget(
            name: "test-posix-socket",
            dependencies: [dependency]
        )
    ]
)

#if os(Windows)
package.targets.append(
    .executableTarget(
        name: "test-wintun",
        dependencies: [dependency]
    )
)
#endif
