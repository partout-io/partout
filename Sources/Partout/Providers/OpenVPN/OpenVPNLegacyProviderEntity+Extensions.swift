// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(PartoutOpenVPN)

import Foundation
#if !PARTOUT_MONOLITH
import PartoutOpenVPN
#endif

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
