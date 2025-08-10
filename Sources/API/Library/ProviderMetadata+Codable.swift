// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import GenericJSON
import PartoutCore

// WARNING: this relies on APIV5Mapper to store [String: JSON] as is from API

extension Provider.Metadata: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let userInfo = try container.decode(JSON.self)
        self.init(userInfo: userInfo)
    }

    public func encode(to encoder: Encoder) throws {
        assert(userInfo is JSON, "Provider.Metadata.userInfo is not a JSON")
        var container = encoder.singleValueContainer()
        try container.encode(userInfo as? JSON)
    }
}
