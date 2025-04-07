![iOS 15+](https://img.shields.io/badge/ios-15+-green.svg)
![macOS 12+](https://img.shields.io/badge/macos-12+-green.svg)
![tvOS 17+](https://img.shields.io/badge/tvos-17+-green.svg)
[![License GPLv3](https://img.shields.io/badge/license-GPLv3-lightgray.svg)](LICENSE)

[![Release](https://github.com/passepartoutvpn/partout/actions/workflows/release.yml/badge.svg)](https://github.com/passepartoutvpn/partout/actions/workflows/release.yml)

# Partout

A scalable framework to build modern network apps.

Binary distribution for these architectures:

- macosx
- iphonesimulator
- appletvsimulator

## Installation

### Testing

Clone the library codebase:

```
$ git clone https://github.com/passepartoutvpn/partout
```

Clone the app codebase in the "Passepartout" directory (do not recurse into submodules):

```
$ git clone https://github.com/passepartoutvpn/passepartout Passepartout
```

Edit `Passepartout/Packages/PassepartoutKit-Framework/Package.swift` and set:

```
environment = .onlineDevelopment
```

Edit `Demo/Config.xcconfig` with your developer details. You must comply with all the capabilities and entitlements in the main app and the tunnel extension target.

Put your configuration files into `Demo/App/Files` with these names:

- OpenVPN configuration: `test-sample.ovpn`
- OpenVPN credentials (in two lines): `test-sample.txt`
- WireGuard configuration: `test-sample.wg`

Open `Demo.xcodeproj` and run the `PartoutDemo` target on your Mac or iOS/tvOS Simulators.

## License

Copyright (c) 2025 Davide De Rosa. All rights reserved.

This project is licensed under the [GPLv3][license-content].

If you want to use this library for proprietary or commercial purposes, please [contact me privately][license-contact].

## Credits

- [GenericJSON][credits-genericjson]

### OpenVPN

© Copyright 2025 OpenVPN | OpenVPN is a registered trademark of OpenVPN, Inc.

### WireGuard

© Copyright 2015-2025 Jason A. Donenfeld. All Rights Reserved. "WireGuard" and the "WireGuard" logo are registered trademarks of Jason A. Donenfeld.

## Contacts

Twitter: [@keeshux][about-twitter]

Website: [passepartoutvpn.app][about-website]

[license-content]: LICENSE
[license-contact]: mailto:license@passepartoutvpn.app

[credits-genericjson]: https://github.com/iwill/generic-json-swift

[about-twitter]: https://twitter.com/keeshux
[about-website]: https://passepartoutvpn.app
