//
//  ProviderServer.swift
//  Partout
//
//  Created by Davide De Rosa on 10/7/24.
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
import PartoutCore

public struct ProviderServer: Identifiable, Hashable, Codable, Sendable {
    public struct Metadata: Hashable, Codable, Sendable {
        public let providerId: ProviderID

        public let categoryName: String

        public let countryCode: String

        public let otherCountryCodes: [String]?

        public let area: String?

//        public let serverIndex: Int?
//
//        public let tags: [String]?
//
//        public let geo: (Double, Double)?

        public init(providerId: ProviderID, categoryName: String, countryCode: String, otherCountryCodes: [String]?, area: String?) {
            self.providerId = providerId
            self.categoryName = categoryName
            self.countryCode = countryCode
            self.otherCountryCodes = otherCountryCodes
            self.area = area
        }
    }

    public var id: String {
        [metadata.providerId.rawValue, serverId].joined(separator: ".")
    }

    public let metadata: Metadata

    public let serverId: String

    public let hostname: String?

    public let ipAddresses: Set<Data>?

    public let supportedModuleTypes: [ModuleType]?

    public let supportedPresetIds: [String]?

    public init(metadata: Metadata, serverId: String, hostname: String?, ipAddresses: Set<Data>?, supportedModuleTypes: [ModuleType]?, supportedPresetIds: [String]?) {
        self.metadata = metadata
        self.serverId = serverId
        self.hostname = hostname
        self.ipAddresses = ipAddresses
        self.supportedModuleTypes = supportedModuleTypes
        self.supportedPresetIds = supportedPresetIds
    }
}

extension ProviderServer {
    public var localizedCountry: String? {
        Locale.current.localizedString(forRegionCode: metadata.countryCode)
    }
}
