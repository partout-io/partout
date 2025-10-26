// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension Module where Self: Hashable {
    public var fingerprint: Int {
        hashValue
    }
}
