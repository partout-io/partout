[![Unit Tests](https://github.com/passepartoutvpn/api-source/actions/workflows/test.yml/badge.svg)](https://github.com/passepartoutvpn/api-source/actions/workflows/test.yml)
[![Publish](https://github.com/passepartoutvpn/api-source/actions/workflows/publish.yml/badge.svg)](https://github.com/passepartoutvpn/api-source/actions/workflows/publish.yml)
[![Cache](https://github.com/passepartoutvpn/api-source/actions/workflows/cache.yml/badge.svg)](https://github.com/passepartoutvpn/api-source/actions/workflows/cache.yml)

# Passepartout API

These files generate the API for the [Passepartout][about-app] client.

## Installation

### Requirements

- Node.js

### Testing

Install the package:

```sh
npm install
```

Fetch the infrastructure of a provider from mocks:

```sh
npm run fetch hideme
```

or from the real provider API:

```sh
npm run fetch hideme 1
```

Run the tests against the mocks:

```sh
npm test
```

## Contributing

Refer to [this document][github-contributing] to learn how to contribute e.g. new providers to the API.

## License

Copyright (c) 2025 Davide De Rosa. All rights reserved.

This project is licensed under the [MIT][license-content].

### Contributing

By contributing to this project you are agreeing to the terms stated in the [Contributor License Agreement (CLA)][contrib-cla].

## Contacts

Twitter: [@keeshux][about-twitter]

Website: [passepartoutvpn.app][about-website]

[license-content]: LICENSE
[contrib-cla]: CLA.rst

[github-contributing]: CONTRIBUTING.md

[about-app]: https://github.com/passepartoutvpn/passepartout
[about-twitter]: https://twitter.com/keeshux
[about-website]: https://passepartoutvpn.app
