// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//  SPDX-License-Identifier: MIT
//  Copyright © 2018-2024 WireGuard LLC. All Rights Reserved.

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

enum LegacyWireGuardConnectionError: Error {
    case dnsResolutionFailure

    case couldNotStartBackend

    case couldNotDetermineFileDescriptor

    case couldNotSetNetworkSettings
}

extension LegacyWireGuardConnectionError: PartoutErrorMappable {
    var asPartoutError: PartoutError {
        PartoutError(.linkNotActive, self)
    }
}
