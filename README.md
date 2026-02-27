![iOS 16+](https://img.shields.io/badge/ios-16+-green.svg)
![macOS 13+](https://img.shields.io/badge/macos-13+-green.svg)
![tvOS 17+](https://img.shields.io/badge/tvos-17+-green.svg)
[![License GPLv3](https://img.shields.io/badge/license-GPLv3-lightgray.svg)](LICENSE)

[![Unit Tests](https://github.com/partout-io/partout/actions/workflows/test.yml/badge.svg)](https://github.com/partout-io/partout/actions/workflows/test.yml)
[![Release](https://github.com/partout-io/partout/actions/workflows/release.yml/badge.svg)](https://github.com/partout-io/partout/actions/workflows/release.yml)

# [Partout](https://partout.io)

_The easiest way to build cross-platform tunnel apps_.

Partout is a _multilanguage_ library using [Swift][swift] and C at its core. It provides VPN functionality through the [Network Extension][network-extension] framework on Apple platforms, but it partially works on Android, Linux, and Windows (with [Wintun][wintun]). I'm documenting the long journey of making Partout fully cross-platform [in a blog series][blog], where I write about the challenges of Swift on non-Apple targets, and how I'm overcoming them.

Partout is the backbone of [Passepartout][passepartout]. The footprint is kept in check on non-Apple platforms by reimplementing a small subset of Swift Foundation in the `MiniFoundation` targets.

## Usage

**As per the GPL, the public license is not suitable for the App Store and other closed-source distributions. If you want to use Partout for proprietary or commercial purposes, please [obtain a proper license][license-website].**

### Swift

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

### Other languages (ABI)

The C ABI is a work in progress.

#### Requirements

- Swift
- C/C++ build tools
- CMake
- ninja
- Android NDK (optional)
- [Swift Android SDK][swift-android-sdk] (optional)

These are the requirements for Partout, but additional build tools may be required depending on the vendors build system.

#### Build

First, fetch all the vendored submodules:

```shell
git submodule init
git submodule update --recursive
```

Then, you will use one of the `scripts/build.*` variants based on the host platform:

- `scripts/build.sh` (bash)
- `scripts/build.ps1` (Windows PowerShell)

The script builds the vendors as static libraries and accepts a few options: 

- `-a`: Build everything
- `-config (Debug|Release)`: The CMake build type
- `-android`: Build for Android
- `-l`: Build the Partout library (opt-in)
- `-crypto (openssl|native)`: Pick a crypto subsystem between OpenSSL and Native/MbedTLS (WIP)
- `-wireguard`: Enable support for WireGuard (requires Go)

For example, this will build Partout for release with a dependency on OpenSSL:

```shell
$ scripts/build.sh -config Release -l -crypto openssl
```

Sample output:

```
bin/<platform-arch>/partout.h       # The Partout ABI
bin/darwin-arm64/libpartout.a       # macOS
bin/linux-aarch64/libpartout.a      # Linux
bin/windows-arm64/libpartout.lib    # Windows
bin/android-aarch64/libpartout.a    # Android
```

Additionally, `libpartout_c` must be linked. Partout must be bundled with the shared vendored libraries and the Swift runtime to work.

Building for Android requires access to external SDKs:

- `$ANDROID_NDK_ROOT` to point to your Android NDK installation
- `$SWIFT_ANDROID_SDK` to point to your Swift for Android SDK installation (e.g. in `~/.swiftpm/swift-sdks`)

The CMake configuration is done with the `android.toolchain.cmake` toolchain. The script runs on macOS, but can be adapted for other platforms with slight tweaks to `scripts/build.sh`.

## Demo

### Xcode

There is an Xcode Demo in the `Examples` directory. Edit `Demo/Config.xcconfig` with your developer details. You must comply with all the capabilities and entitlements in the main app and the tunnel extension target.

Put your configuration files into `Demo/App/Files` with these names:

- OpenVPN configuration: `test-sample.ovpn`
- OpenVPN credentials (in two lines): `test-sample.txt`
- WireGuard configuration: `test-sample.wg`

Open `Demo.xcodeproj` and run the `PartoutDemo` target.

## License

Copyright (c) 2026 Davide De Rosa. All rights reserved.

The library is licensed under the [GPLv3][license]. The `MiniFoundation` targets are MIT-licensed.

### Contributing

By contributing to this project you are agreeing to the terms stated in the [Contributor License Agreement (CLA)][contrib-cla]. For more details please see [CONTRIBUTING][contrib-readme].

## Credits

Libraries:

- [GenericJSON][credits-genericjson]
- [MbedTLS][credits-mbedtls]
- [OpenSSL][credits-openssl]
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

Website: [partout.io][about-website]

[passepartout]: https://passepartoutvpn.app/
[swift]: https://swift.org/
[swift-android-sdk]: https://github.com/swift-android-sdk/swift-android-sdk
[network-extension]: https://developer.apple.com/documentation/networkextension/
[wintun]: https://git.zx2c4.com/wintun/about/
[blog]: https://davidederosa.com/cross-platform-swift/
[license]: LICENSE
[license-website]: https://partout.io/license
[contrib-cla]: CLA.rst
[contrib-readme]: CONTRIBUTING.md

[github-releases]: https://github.com/partout-io/partout/releases
[credits-genericjson]: https://github.com/iwill/generic-json-swift
[credits-mbedtls]: https://github.com/Mbed-TLS/mbedtls
[credits-openssl]: https://github.com/openssl/openssl
[credits-tmthecoder]: https://github.com/tmthecoder
[credits-tmthecoder-xor]: https://github.com/partout-io/tunnelkit/pull/255
[credits-url.c]: https://github.com/cozis/url.c
[credits-uuidv4]: https://github.com/rxi/uuid4
[credits-wintun]: https://github.com/wireguard/wintun
[credits-wireguard-go]: https://github.com/wireguard/wireguard-go

[about-twitter]: https://twitter.com/keeshux
[about-website]: https://github.com/partout-io
