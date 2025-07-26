// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import PartoutWireGuard

// MARK: - Mapping

extension WireGuardConnectionError: PartoutErrorMappable {
    var asPartoutError: PartoutError {
        PartoutError(.connectionNotStarted, self)
    }
}

extension WireGuardParseError: PartoutErrorMappable {
    public var asPartoutError: PartoutError {
        PartoutError(.parsing, self)
    }
}
