# Apple (Network Extension)

Mappings to the Network Extension framework.

## Overview

The way [Network Extension](https://developer.apple.com/documentation/networkextension) operates is normally split into two targets:

- App
- App Extension

The App is only in charge of simple tasks:

- Configure the ``Tunnel`` with a ``TunnelStrategy`` and a ``Profile``
- Manage and observe the tunnel status, e.g. in the UI

On the other hand, the App Extension is responsible of the most complex part, namely:

- Parse the ``Profile`` into a set of ``Module``
- Connect to the ``ConnectionModule``, in case the profile has one
- Apply the network settings found in the other modules

The ``NEPTPForwarder`` wrapper is a simple way to build a basic [NEPacketTunnelProvider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider), which is type of App Extension you want to pick for your tunnel service on the Apple platforms. It mimics the `NEPacketTunnelProvider` API one-by-one, as you can see from the `PacketTunnelProvider` class in the Demo project.

## Topics

### App

- ``_PartoutVendorsAppleNE/NETunnelManagerRepository``
- ``_PartoutVendorsAppleNE/NETunnelStrategy``
- ``_PartoutVendorsAppleNE/NETunnelEnvironment``

### App Extension

- ``_PartoutVendorsAppleNE/NEPTPForwarder``
- ``_PartoutVendorsAppleNE/NESettingsApplying``
- ``_PartoutVendorsAppleNE/NESettingsModule``
- ``_PartoutVendorsAppleNE/NEObservablePath``

### Serialization

- ``_PartoutVendorsAppleNE/NEProtocolCoder``
- ``_PartoutVendorsAppleNE/NEProtocolDecoder``
- ``_PartoutVendorsAppleNE/NEProtocolEncoder``
- ``_PartoutVendorsAppleNE/ProviderNEProtocolCoder``
- ``_PartoutVendorsAppleNE/KeychainNEProtocolCoder``

### Connection

- ``_PartoutVendorsAppleNE/NEInterfaceFactory``
- ``_PartoutVendorsAppleNE/NEUDPObserver``
- ``_PartoutVendorsAppleNE/NETCPObserver``
- ``_PartoutVendorsAppleNE/NETunnelInterface``
- ``_PartoutVendorsAppleNE/NETunnelController``
