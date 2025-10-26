![iOS 15+](https://img.shields.io/badge/ios-15+-green.svg)
![macOS 12+](https://img.shields.io/badge/macos-12+-green.svg)
![tvOS 17+](https://img.shields.io/badge/tvos-17+-green.svg)
[![License GPLv3](https://img.shields.io/badge/license-GPLv3-lightgray.svg)](LICENSE)

[![Unit Tests](https://github.com/partout-io/partout/actions/workflows/test.yml/badge.svg)](https://github.com/partout-io/partout/actions/workflows/test.yml)
[![Release](https://github.com/partout-io/partout/actions/workflows/release.yml/badge.svg)](https://github.com/partout-io/partout/actions/workflows/release.yml)

# [Partout](https://partout.io)

The easiest way to build cross-platform tunnel apps.

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
- Swift Android SDK (optional)

These are the requirements for Partout, but additional build tools may be required depending on the vendors build system. Bear in mind that the generated library will still need to be bundled with the proper Swift runtime.

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

- `-l`: Build Partout as dynamic library (opt-in)
- `-config (Debug|Release)`: The CMake build type
- `-crypto (openssl|native)`: The crypto subsystem to pick between OpenSSL and Native/MbedTLS
- `-wireguard`: Enable support for WireGuard (requires Go)

For example, this will build Partout for release with a static dependency on OpenSSL:

```shell
$ scripts/build.sh -config Release -crypto openssl -l
```

Sample output:

```
.bin/partout.h                       # The Partout ABI
.bin/darwin-arm64/libpartout.dylib   # macOS
.bin/linux-aarch64/libpartout.so     # Linux
.bin/windows-arm64/partout.dll       # Windows
```

This should work for all platforms, except for Android, which asks for a hybrid CMake + SwiftPM approach.

#### Build for Android

Building for Android requires access to a Swift Android SDK, and this is not straightforward from CMake. That's why the `scripts/build-android.sh` script does the heavy-lifting in two steps:

- Cross-compile the vendored static libraries with CMake for Android
- Embed the static libraries in SwiftPM to generate a dynamic library with the Swift Android SDK

Requirements:

- Set `$ANDROID_NDK_ROOT` to point to your Android NDK installation
- Add the NDK toolchain to the `$PATH`

The script runs on macOS, but can be adapted for other platforms with slight tweaks to `scripts/build.sh`. The Android output is consistent with the other platforms:

```
.bin/partout.h
.bin/android-arm64/libpartout.so
```

## Demo

### Xcode

There is an Xcode Demo in the `Examples` directory. Edit `Demo/Config.xcconfig` with your developer details. You must comply with all the capabilities and entitlements in the main app and the tunnel extension target.

Put your configuration files into `Demo/App/Files` with these names:

- OpenVPN configuration: `test-sample.ovpn`
- OpenVPN credentials (in two lines): `test-sample.txt`
- WireGuard configuration: `test-sample.wg`

Open `Demo.xcodeproj` and run the `PartoutDemo` target.

## License

Copyright (c) 2025 Davide De Rosa. All rights reserved.

The library is licensed under the [GPLv3][license].

### Contributing

By contributing to this project you are agreeing to the terms stated in the [Contributor License Agreement (CLA)][contrib-cla]. For more details please see [CONTRIBUTING][contrib-readme].

## Credits

- [GenericJSON][credits-genericjson]
- [Tejas Mehta][credits-tmthecoder] for the implementation of the [OpenVPN XOR patch][credits-tmthecoder-xor]

### OpenVPN

© Copyright 2025 OpenVPN | OpenVPN is a registered trademark of OpenVPN, Inc.

### WireGuard

© Copyright 2015-2025 Jason A. Donenfeld. All Rights Reserved. "WireGuard" and the "WireGuard" logo are registered trademarks of Jason A. Donenfeld.

## Contacts

Twitter: [@keeshux][about-twitter]

Website: [partout.io][about-website]

[license]: LICENSE
[license-website]: https://partout.io/license
[contrib-cla]: CLA.rst
[contrib-readme]: CONTRIBUTING.md

[github-releases]: https://github.com/partout-io/partout/releases
[credits-genericjson]: https://github.com/iwill/generic-json-swift
[credits-tmthecoder]: https://github.com/tmthecoder
[credits-tmthecoder-xor]: https://github.com/partout-io/tunnelkit/pull/255

[about-twitter]: https://twitter.com/keeshux
[about-website]: https://github.com/partout-io
