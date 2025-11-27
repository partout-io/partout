# Starting a Tunnel

Start a tunnel daemon to enforce a network configuration and optionally establish a remote connection.

## Overview

Given the main app and the daemon:

- The app installs a ``Profile`` and starts the tunnel daemon with ``Tunnel/install(_:connect:options:title:)``.
- The daemon, typically a ``SimpleConnectionDaemon``, receives the ``Profile``.
- If applicable, the daemon establishes and maintains the ``Connection`` described by the ``ConnectionModule`` of the profile.
- The profile is converted to a network configuration with ``TunnelController/setTunnelSettings(with:)``.

## Topics

### Starting a background service

- ``ConnectionDaemon``
- ``DefaultMessageHandler``
- ``MessageHandler``
- ``NetworkObserver``
- ``ReachabilityObserver``
- ``SimpleConnectionDaemon``

### Setting up a connection

- ``BetterPathBlock``
- ``Connection``
- ``ConnectionParameters``
- ``ConnectionStatus``
- ``CyclingConnection``
- ``DataCount``
- ``EndpointResolver``
- ``NetworkInterfaceFactory``
- ``POSIXInterfaceFactory``

### DNS resolution

- ``DNSRecord``
- ``DNSResolver``
- ``POSIXDNSStrategy``
- ``SimpleDNSResolver``
- ``SimpleDNSStrategy``

### I/O interfaces

- ``AutoUpgradingLink``
- ``IOInterface``
- ``LinkInterface``
- ``LinkObserver``
- ``POSIXBlockingSocket``
- ``POSIXSocketObserver``
- ``SocketIOInterface``
- ``VirtualTunnelInterface``

### Applying network settings

- ``TunnelController``
- ``TunnelRemoteInfo``
- ``VirtualTunnelController``
- ``VirtualTunnelControllerImpl``
