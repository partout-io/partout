// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import _PartoutWireGuard_C
import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

enum WireGuardAdapterError: Error, Sendable {
    /// Failure to locate tunnel file descriptor.
    case cannotLocateTunnelFileDescriptor

    /// Failure to perform an operation in such state.
    case invalidState

    /// Failure to set network settings.
    case setNetworkSettings(Error)

    /// Failure to start WireGuard backend.
    case startWireGuardBackend(Int32)
}
