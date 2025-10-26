# Managing a Tunnel

Control a tunnel service and interact with its environment.

## Overview

Control the daemon started in <doc:StartingTunnel> and be informed about its current state. The way the ``Tunnel`` actor communicates with the daemon is agnostic of the OS and implemented in a ``TunnelStrategy``.

## Topics

### Interacting with a tunnel

- ``Tunnel``
- ``TunnelStrategy``
- ``TunnelObservableStrategy``
- ``TunnelStatus``
- ``TunnelActiveProfile``
- ``FakeTunnelStrategy``
- ``Message``

### IPC

- ``TunnelEnvironment``
- ``TunnelEnvironmentKey``
- ``TunnelEnvironmentKeyProtocol``
- ``TunnelEnvironmentKeys``
- ``TunnelEnvironmentReader``
- ``TunnelEnvironmentWriter``
- ``SharedTunnelEnvironment``
- ``StaticTunnelEnvironment``
