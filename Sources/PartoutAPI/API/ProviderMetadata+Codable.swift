//
//  ProviderMetadata+Codable.swift
//  Partout
//
//  Created by Davide De Rosa on 11/29/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

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
