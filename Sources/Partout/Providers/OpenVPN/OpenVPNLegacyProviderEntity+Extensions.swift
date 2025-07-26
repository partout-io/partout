//
//  OpenVPNLegacyProviderEntity+Extensions.swift
//  Partout
//
//  Created by Davide De Rosa on 12/2/24.
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

#if canImport(PartoutOpenVPN)

import Foundation
import PartoutOpenVPN

extension OpenVPNLegacyProviderEntity {
    public func upgraded() throws -> ProviderEntity {
        ProviderEntity(
            server: server.upgraded(),
            preset: try preset.upgraded(),
            heuristic: heuristic?.upgraded()
        )
    }
}

private extension OpenVPNLegacyProviderServer {
    func upgraded() -> ProviderServer {
        ProviderServer(
            metadata: ProviderServer.Metadata(
                providerId: ProviderID(rawValue: metadata.providerId.rawValue),
                categoryName: metadata.categoryName,
                countryCode: metadata.countryCode,
                otherCountryCodes: metadata.otherCountryCodes,
                area: metadata.area
            ),
            serverId: metadata.serverId,
            hostname: hostname,
            ipAddresses: ipAddresses,
            supportedModuleTypes: [.openVPN],
            supportedPresetIds: metadata.supportedPresetIds
        )
    }
}

private extension OpenVPNLegacyProviderPreset {
    func upgraded() throws -> ProviderPreset {
        let newTemplate = OpenVPNProviderTemplate(configuration: template, endpoints: endpoints)
        let newTemplateData = try JSONEncoder().encode(newTemplate)
        return ProviderPreset(
            providerId: ProviderID(rawValue: providerId.rawValue),
            presetId: presetId,
            description: description,
            moduleType: .openVPN,
            templateData: newTemplateData
        )
    }
}

private extension OpenVPNLegacyProviderHeuristic {
    func upgraded() -> ProviderHeuristic? {
        switch self {
        case .sameCountry(let countryCode):
            return .sameCountry(countryCode)

        case .sameRegion(let region):
            return .sameRegion(ProviderRegion(
                countryCode: region.countryCode,
                area: region.area
            ))
        }
    }
}

#endif
