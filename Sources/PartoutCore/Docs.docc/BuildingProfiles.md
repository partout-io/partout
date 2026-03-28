# Modules and Profiles

Compose modules into profiles, the building blocks of a network configuration.

## Overview

Profiles are the foundations of Partout, and profiles are made of modules. A basic ``Module`` may statically represent a subset of the network settings of a device (e.g. DNS), whereas a ``ConnectionModule`` describes how to establish a connection to a remote service in order to obtain and apply such settings (e.g. VPN, tunnel, proxy).

## Topics

### Profile structure

- ``Profile``
- ``ProfileHeader``
- ``ProfileType``
- ``MutableProfileType``
- ``ProfileBehavior``

### Defining profile modules

- ``Module``
- ``ModuleBuilder``
- ``ModuleType``
- ``ConnectionModule``

### Strategies

- ``ModuleBuilderValidator``
- ``ModuleImplementation``
- ``ModuleImporter``
- ``ModuleRegistry``
- ``ConnectionFactory``
- ``Resolver``

### Serialization

- ``ConfigurationCoder``
- ``ConfigurationDecoder``
- ``ConfigurationEncoder``
- ``SerializableConfiguration``
- ``SerializableModule``
- ``ProfileCoder``
- ``ProfileEncoder``
- ``ProfileDecoder``
- ``LegacyModuleDecoder``

### Bundled modules

- ``CustomModule``
- ``DNSModule``
- ``DNSProtocol``
- ``HTTPProxyModule``
- ``IPModule``
- ``OnDemandModule``
- ``TransientModule``

### Builder pattern

- ``BuilderType``
- ``BuildableType``
