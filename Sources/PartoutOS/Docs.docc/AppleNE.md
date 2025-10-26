# Apple (Network Extension)

Mappings to the Network Extension framework.

## Overview

The way [Network Extension](https://developer.apple.com/documentation/networkextension) operates is normally split into two targets:

- App
- App Extension

The App is only in charge of simple tasks:

- Configure the tunnel with a strategy and a profile
- Manage and observe the tunnel status, e.g. in the UI

On the other hand, the App Extension is responsible of the most complex part, namely:

- Parse the profile into a set of modules
- Connect to the main connection module, in case the profile has one
- Apply the network settings found in the other modules

The ``NEPTPForwarder`` wrapper is a simple way to build a basic [NEPacketTunnelProvider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider), which is type of App Extension you want to pick for your tunnel service on the Apple platforms. It mimics the `NEPacketTunnelProvider` API one-by-one, as you can see from the `PacketTunnelProvider` class in the Demo project.

## Topics

### App

- ``NETunnelEnvironment``
- ``NETunnelManagerRepository``
- ``NETunnelStrategy``

### App Extension

- ``NEObservablePath``
- ``NEPTPForwarder``
- ``NESettingsApplying``
- ``NESettingsModule``

### Serialization

- ``KeychainNEProtocolCoder``
- ``NEProtocolCoder``
- ``NEProtocolDecoder``
- ``NEProtocolEncoder``
- ``ProviderNEProtocolCoder``

### Connection

- ``NEInterfaceFactory``
- ``NESocketObserver``
- ``NETCPObserver``
- ``NETunnelInterface``
- ``NETunnelController``
- ``NEUDPObserver``
