# Modules and Profiles

Compose modules into profiles, the building blocks of a network configuration.

## Overview

Profiles are the foundations of Partout, and profiles are made of modules. A basic ``Module`` may statically represent a subset of the network settings of a device (e.g. DNS), whereas a ``ConnectionModule`` describes how to establish a connection to a remote service in order to obtain and apply such settings (e.g. VPN, tunnel, proxy).

## Topics

### Profile management

- ``Profile``
- ``ProfileHeader``
- ``Registry``
- ``ProfileType``
- ``MutableProfileType``
- ``ProfileBehavior``

### Defining profile modules

- ``Module``
- ``ModuleBuilder``
- ``ModuleBuilderValidator``
- ``ModuleType``
- ``ModuleHandler``
- ``ModuleImplementation``
- ``ConnectionModule``
- ``LoggableModule``
- ``ModuleImporter``
- ``ConfigurationCoder``
- ``ConfigurationEncoder``
- ``ConfigurationDecoder``

### Serialization

- ``CodableProfile``
- ``CodableModule``

### Bundled modules

- ``DNSModule``
- ``DNSProtocol``
- ``FilterModule``
- ``HTTPProxyModule``
- ``IPModule``
- ``OnDemandModule``

### Builder pattern

- ``BuilderType``
- ``BuildableType``
