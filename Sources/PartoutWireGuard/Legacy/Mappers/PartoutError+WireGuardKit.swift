// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutWireGuard
#endif

// MARK: - Mapping

extension LegacyWireGuardConnectionError: PartoutErrorMappable {
    var asPartoutError: PartoutError {
        PartoutError(.linkNotActive, self)
    }
}

extension WireGuardParseError: PartoutErrorMappable {
    public var asPartoutError: PartoutError {
        PartoutError(.parsing, self)
    }
}
