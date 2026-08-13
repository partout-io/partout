![iOS 16+](https://img.shields.io/badge/ios-16+-green.svg)
![macOS 13+](https://img.shields.io/badge/macos-13+-green.svg)
![tvOS 17+](https://img.shields.io/badge/tvos-17+-green.svg)
[![License GPLv3](https://img.shields.io/badge/license-GPLv3-lightgray.svg)](LICENSE)

[![Unit Tests](https://github.com/partout-io/partout/actions/workflows/test.yml/badge.svg)](https://github.com/partout-io/partout/actions/workflows/test.yml)
[![Release](https://github.com/partout-io/partout/actions/workflows/release.yml/badge.svg)](https://github.com/partout-io/partout/actions/workflows/release.yml)

# [Partout][partout]

_The easiest way to build cross-platform tunnel apps_.

Partout (French: /paʁtu/) is a tunnel library that uses Zig and C at its core, plus Swift and Kotlin for the OS bindings. It provides VPN functionality through the [Network Extension][apple-ne] framework on Apple platforms, through [VpnService][android-vpnservice] on Android, and it partially works on Windows (with [Wintun][wintun]) and Linux.

Partout is the backbone of [Passepartout][passepartout].

## Usage

**As per the GPL, the public license is not suitable for the App Store and other closed-source distributions. If you want to use Partout for proprietary or commercial purposes, please [obtain a proper license][partout-license].**

### SwiftPM

Import the library as a SwiftPM dependency:

```swift
dependencies: [
    .package(url: "https://github.com/partout-io/partout", branch: "master")
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: ["partout"]
    )
]
```

### CMake

CMake is a thin wrapper around the Zig build. It resolves the selected vendors,
then invokes `zig build install` with their include and library paths.

#### Requirements

- Zig 0.16+
- C build tools
- CMake
- ninja
- Android NDK (optional)

Partout consumes system libraries or artifacts published by the [prebuilts][github-prebuilts] project; it does not build vendor sources.

#### Build

Use one of the `scripts/build.*` variants based on the host platform:

- `scripts/build.sh` (bash)
- `scripts/build.ps1` (Windows PowerShell)

The script resolves the selected dependencies and accepts a few options:

- `-h`, `--help`: Show the build help
- `-gen`: Configure CMake
- `-install <dir>`: Install the completed build artifacts into a directory
- `-config (Debug|Release)`: The CMake build type (`build.sh` only)
- `-crypto (openssl|mbedtls[,openssl|mbedtls...])`: Pick one or more crypto subsystems between OpenSSL and Native/MbedTLS
- `-wireguard`: Enable WireGuard
- `-android`: Build for Android
- `-prebuilts <version>`: Use vendor archives from the matching [`partout-io/prebuilts`][github-prebuilts] GitHub Release. CMake derives each archive name from the vendor, platform, and architecture. On macOS and Linux, CMake tries the system library first and uses the release only as a fallback.

The equivalent CMake variable is `PP_BUILD_VENDOR_PREBUILT_URL`. Optional
vendor-specific `*_PREBUILT_HASH` variables accept a CMake `URL_HASH` value
such as `SHA256=<digest>`.

After the initial `-gen`, invoke the script without arguments to rebuild the
existing configuration.

For example, this will build Partout for release with a dependency on OpenSSL:

```shell
$ scripts/build.sh -gen -config Release -crypto openssl
```

Sample output:

```
# macOS
bin/darwin-arm64/partout/lib/libpartout.dylib
# Linux
bin/linux-aarch64/partout/lib/libpartout.so
# Android
bin/android-aarch64/partout/lib/libpartout.so
# Windows
bin/windows-arm64/partout/bin/partout.dll
```

Partout must be bundled with the enabled shared vendor libraries to work. Building for Android requires access to the Android NDK.

Check out `scripts/build.sh` and `scripts/build.ps1` for more details.

## Demo

### Xcode

There is an Xcode Demo in the `cross/apple` directory. Edit `Demo/Config.xcconfig` with your developer details. You must comply with all the capabilities and entitlements in the main app and the tunnel extension target.

Put your configuration files into `Demo/App/Files` with these names:

- OpenVPN configuration: `test-sample.ovpn`
- OpenVPN credentials (in two lines): `test-sample.txt`
- WireGuard configuration: `test-sample.wg`

Open `Demo.xcodeproj` and run the `PartoutDemo` target.

## License

Copyright (c) 2026 Davide De Rosa. All rights reserved.

The library is licensed under the [GPLv3][license].

### Contributing

By contributing to this project you are agreeing to the terms stated in the [Contributor License Agreement (CLA)][contrib-cla]. For more details please see [CONTRIBUTING][contrib-readme].

## Credits

Libraries:

- [GenericJSON][credits-genericjson]
- [MbedTLS][credits-mbedtls]
- [OpenSSL][credits-openssl]
- [SwiftSyntax][credits-swift-syntax]
- [url.c][credits-url.c]
- [Wintun][credits-wintun]
- [WireGuard (Go)][credits-wireguard-go]

Special contributors:

- [Tejas Mehta][credits-tmthecoder] for the implementation of the [OpenVPN XOR patch][credits-tmthecoder-xor]

### OpenSSL

This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/)

### OpenVPN

© Copyright 2026 OpenVPN | OpenVPN is a registered trademark of OpenVPN, Inc.

### WireGuard

© Copyright 2015-2026 Jason A. Donenfeld. All Rights Reserved. "WireGuard" and the "WireGuard" logo are registered trademarks of Jason A. Donenfeld.

## Contacts

Twitter: [@keeshux][about-twitter]

Website: [partout.io][partout]

[partout]: https://partout.io
[partout-license]: https://partout.io/license/
[passepartout]: https://partout.io/passepartout/
[apple-ne]: https://developer.apple.com/documentation/networkextension/
[android-vpnservice]: https://developer.android.com/reference/android/net/VpnService
[wintun]: https://git.zx2c4.com/wintun/about/
[license]: LICENSE
[contrib-cla]: CLA.rst
[contrib-readme]: CONTRIBUTING.md

[github-prebuilts]: https://github.com/partout-io/prebuilts

[credits-genericjson]: https://github.com/iwill/generic-json-swift
[credits-mbedtls]: https://github.com/Mbed-TLS/mbedtls
[credits-openssl]: https://github.com/openssl/openssl
[credits-swift-syntax]: https://github.com/swiftlang/swift-syntax
[credits-tmthecoder]: https://github.com/tmthecoder
[credits-tmthecoder-xor]: https://github.com/partout-io/tunnelkit/pull/255
[credits-url.c]: https://github.com/cozis/url.c
[credits-wintun]: https://github.com/wireguard/wintun
[credits-wireguard-go]: https://github.com/wireguard/wireguard-go

[about-twitter]: https://twitter.com/keeshux
