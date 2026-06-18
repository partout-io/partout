// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

internal import _PartoutWireGuard_C
#if !USE_CMAKE
import PartoutCore
#endif

enum WireGuardAdapterError: Error, Sendable {
    /// Failure to locate tunnel file descriptor.
    case cannotLocateTunnelFileDescriptor

    /// Failure to resolve peer endpoints.
    case dnsResolution([Endpoint])

    /// Failure to perform an operation in such state.
    case invalidState

    /// Failure to set network settings.
    case setNetworkSettings(Error)

    /// Failure to start WireGuard backend.
    case startWireGuardBackend(Int32)
}
