// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Partout

extension Registry {
    func withLegacyEncoding(_ legacy: Bool) -> CodingRegistry {
        CodingRegistry(registry: self, withLegacyEncoding: legacy)
    }
}
