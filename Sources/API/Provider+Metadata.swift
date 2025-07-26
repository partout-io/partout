// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

extension Provider {
    public struct Metadata: UserInfoCodable, Hashable {
        public let userInfo: AnyHashable?

        public init(userInfo: AnyHashable? = nil) {
            self.userInfo = userInfo
        }
    }
}
