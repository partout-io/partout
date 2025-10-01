// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PartoutExamples",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "test-abi",
            dependencies: ["partout"]
        ),
        .executableTarget(
            name: "test-posix-socket",
            dependencies: ["partout"]
        )
    ]
)

#if os(Windows)
package.targets.append(
    .executableTarget(
        name: "test-wintun",
        dependencies: ["partout"]
    )
)
#endif
