# ``PartoutCore``

The foundations of Partout.

## Overview

Partout provides a framework to build network profiles in a cross-platform and implementation-agnostic fashion. Your application should be split into a main app, acting as a controller, and a tunnel daemon, that performs the low-level operations that modify the device network settings. The way the app and the daemon speak to each other, and how the network configurations are committed and maintained, are taken care of by Partout.

### Building a Profile

The central part of the library is the ``Profile`` structure, composed of a set of ``Module`` that represent a flexible and abstract network configuration. See <doc:BuildingProfiles>.

### Starting the Tunnel

The tunnel daemon is the core business in that it's responsible for converting a ``Profile`` to actionable network settings and communication. The ``SimpleConnectionDaemon`` class is the main orchestrator of the tunnel service. See <doc:StartingTunnel>.

### Managing the Tunnel

The app controls the tunnel daemon with the ``Tunnel`` class, observes its status, and manages the installed profiles. See <doc:ManagingTunnel>.

### Utilities

Partout features a set of [general-purpose entities](<doc:Misc>), including [loggers and error handlers](<doc:LoggingErrors>). Unless specified otherwise, integer time values are expressed in milliseconds in the whole library.

## Topics

- <doc:Globals>
- <doc:BuildingProfiles>
- <doc:StartingTunnel>
- <doc:ManagingTunnel>
- <doc:LoggingErrors>
- <doc:Misc>
- <doc:Testing>
