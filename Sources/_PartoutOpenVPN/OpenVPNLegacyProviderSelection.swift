//
//  OpenVPNLegacyProviderSelection.swift
//  Partout
//
//  Created by Davide De Rosa on 3/16/25.
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

@available(*, deprecated, message: "Backward-compatibility with persisted modules before ProviderModule")
public struct OpenVPNLegacyProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

@available(*, deprecated, message: "Backward-compatibility with persisted modules before ProviderModule")
public struct OpenVPNLegacyProviderSelection: Hashable, Codable, Sendable {
    public var id: OpenVPNLegacyProviderID

    public var entity: OpenVPNLegacyProviderEntity?
}

@available(*, deprecated, message: "Backward-compatibility with persisted modules before ProviderModule")
public struct OpenVPNLegacyProviderEntity: Hashable, Codable, Sendable {
    public let server: OpenVPNLegacyProviderServer

    public let preset: OpenVPNLegacyProviderPreset

    public let heuristic: OpenVPNLegacyProviderHeuristic?
}

@available(*, deprecated, message: "Backward-compatibility with persisted modules before ProviderModule")
public struct OpenVPNLegacyProviderServer: Hashable, Codable, Sendable {
    public struct Metadata: Hashable, Codable, Sendable {
        public enum CodingKeys: String, CodingKey {
            case providerId = "id"

            case serverId

            case supportedConfigurationIdentifiers

            case supportedPresetIds

            case categoryName

            case countryCode

            case otherCountryCodes

            case area
        }

        public let providerId: OpenVPNLegacyProviderID

        public let serverId: String

        public let supportedConfigurationIdentifiers: [String]?

        public let supportedPresetIds: [String]?

        public let categoryName: String

        public let countryCode: String

        public let otherCountryCodes: [String]?

        public let area: String?
    }

    public enum CodingKeys: String, CodingKey {
        case metadata = "provider"

        case hostname

        case ipAddresses
    }

    public let metadata: Metadata

    public let hostname: String?

    public let ipAddresses: Set<Data>?
}

@available(*, deprecated, message: "Backward-compatibility with persisted modules before ProviderModule")
public struct OpenVPNLegacyProviderPreset: Hashable, Codable, Sendable {
    public enum CodingKeys: String, CodingKey {
        case providerId

        case presetId

        case description

        case endpoints

        case template = "configuration"
    }

    public let providerId: OpenVPNLegacyProviderID

    public let presetId: String

    public let description: String

    public let endpoints: [EndpointProtocol]

    public let template: OpenVPN.Configuration
}

@available(*, deprecated, message: "Backward-compatibility with persisted modules before ProviderModule")
public enum OpenVPNLegacyProviderHeuristic: Hashable, Codable, Sendable {
    public struct Region: Identifiable, Hashable, Codable, Sendable {
        public let id: String

        public let countryCode: String

        public let area: String?
    }

    case sameCountry(String)

    case sameRegion(Region)
}
