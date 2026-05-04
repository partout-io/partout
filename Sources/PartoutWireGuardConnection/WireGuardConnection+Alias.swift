// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//  SPDX-License-Identifier: MIT
//  Copyright © 2018-2024 WireGuard LLC. All Rights Reserved.

#if !USE_CMAKE
public typealias WireGuardConnection = _WireGuardConnectionV1
#else
public typealias WireGuardConnection = _WireGuardConnectionV2
#endif

enum WireGuardConnectionError: Error {
    case dnsResolutionFailure

    case couldNotStartBackend

    case couldNotDetermineFileDescriptor

    case couldNotSetNetworkSettings
}

extension WireGuardConnectionError: PartoutErrorMappable {
    var asPartoutError: PartoutError {
        PartoutError(.linkNotActive, self)
    }
}
