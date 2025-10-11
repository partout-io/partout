// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension Provider {
    public struct Metadata: Hashable, Codable, Sendable {
        public let userInfo: JSON?

        public init(userInfo: JSON? = nil) {
            self.userInfo = userInfo
        }
    }
}
