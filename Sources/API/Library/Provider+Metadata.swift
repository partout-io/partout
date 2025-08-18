// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
import PartoutCore
#endif

extension Provider {
    public struct Metadata: UserInfoCodable, Hashable, @unchecked Sendable {
        public let userInfo: AnyHashable?

        public init(userInfo: AnyHashable? = nil) {
            self.userInfo = userInfo
        }
    }
}
