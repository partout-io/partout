//
//  ProviderRegion.swift
//  Partout
//
//  Created by Davide De Rosa on 3/6/25.
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

public struct ProviderRegion: Identifiable, Hashable, Codable, Sendable {
    public let id: String

    public let countryCode: String

    public let area: String?

    public init(countryCode: String, area: String?) {
        id = Self.id(countryCode: countryCode, area: area)
        self.countryCode = countryCode
        self.area = area
    }
}

extension ProviderRegion {
    public static func id(countryCode: String, area: String?) -> String {
        "\(countryCode).\(area ?? "*")"
    }
}

extension ProviderServer {
    public var region: ProviderRegion {
        ProviderRegion(countryCode: metadata.countryCode, area: metadata.area)
    }

    public var regionId: String {
        ProviderRegion.id(countryCode: metadata.countryCode, area: metadata.area)
    }
}
