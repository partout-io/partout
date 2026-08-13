// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Module where Self: Hashable {
    public var fingerprint: Int {
        hashValue
    }
}
