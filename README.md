![iOS 15+](https://img.shields.io/badge/ios-15+-green.svg)
![macOS 12+](https://img.shields.io/badge/macos-12+-green.svg)
![tvOS 17+](https://img.shields.io/badge/tvos-17+-green.svg)
[![License GPLv3](https://img.shields.io/badge/license-GPLv3-lightgray.svg)](LICENSE)

[![Unit Tests](https://github.com/passepartoutvpn/partout/actions/workflows/test.yml/badge.svg)](https://github.com/passepartoutvpn/partout/actions/workflows/test.yml)
[![Core](https://github.com/passepartoutvpn/partout/actions/workflows/release_core.yml/badge.svg)](https://github.com/passepartoutvpn/partout/actions/workflows/release_core.yml)

# Partout

A scalable framework to build modern network apps.

Binary distribution for these architectures:

- macosx
- iphonesimulator
- appletvsimulator

__DISCLAIMER: the library is still undergoing deep architectural changes.__

## Installation

### Usage

Import the library as submodule:

```
$ git submodule add https://github.com/passepartoutvpn/partout
$ git submodule update --init
```

then edit `Package.swift` and set:

```
environment = .onlineDevelopment
```

Import the Swift packages under "Plugins" as needed.

Beware that the public framework only supports development on your Mac or iOS/tvOS Simulators. If you want to use the library for proprietary or commercial purposes, please [contact me privately][license-contact].

### Demo

Edit `Demo/Config.xcconfig` with your developer details. You must comply with all the capabilities and entitlements in the main app and the tunnel extension target.

Put your configuration files into `Demo/App/Files` with these names:

- OpenVPN configuration: `test-sample.ovpn`
- OpenVPN credentials (in two lines): `test-sample.txt`
- WireGuard configuration: `test-sample.wg`

Open `Demo.xcodeproj` and run the `PartoutDemo` target.

## License

Copyright (c) 2025 Davide De Rosa. All rights reserved.

The core package is distributed as a binary framework in [GitHub Releases][github-releases] and is licensed under the [MIT][license-mit].

Anything else is licensed under the [GPLv3][license-gpl].

### Contributing

By contributing to this project you are agreeing to the terms stated in the [Contributor License Agreement (CLA)][contrib-cla]. For more details please see [CONTRIBUTING][contrib-readme].

## Credits

- [GenericJSON][credits-genericjson]

### OpenVPN

© Copyright 2025 OpenVPN | OpenVPN is a registered trademark of OpenVPN, Inc.

### WireGuard

© Copyright 2015-2025 Jason A. Donenfeld. All Rights Reserved. "WireGuard" and the "WireGuard" logo are registered trademarks of Jason A. Donenfeld.

## Contacts

Twitter: [@keeshux][about-twitter]

Website: [passepartoutvpn.app][about-website]

[license-gpl]: LICENSE.gpl
[license-mit]: LICENSE.mit
[license-contact]: mailto:license@passepartoutvpn.app
[contrib-cla]: CLA.rst
[contrib-readme]: CONTRIBUTING.md

[github-releases]: https://github.com/passepartoutvpn/partout/releases
[credits-genericjson]: https://github.com/iwill/generic-json-swift

[about-twitter]: https://twitter.com/keeshux
[about-website]: https://passepartoutvpn.app
