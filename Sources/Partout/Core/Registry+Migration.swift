// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
#if canImport(PartoutOpenVPN)
import PartoutOpenVPN
#endif
import PartoutProviders

extension Registry {

    @Sendable
    static func migratedProfile(_ profile: Profile) -> Profile? {
        do {
            switch profile.version {
            case nil:
                var builder = profile.builder(withNewId: false, forUpgrade: true)

#if canImport(PartoutOpenVPN)
                // look for OpenVPN provider modules
                let ovpnPairs: [(offset: Int, module: OpenVPNModule)] = profile.modules
                    .enumerated()
                    .compactMap {
                        guard let module = $0.element as? OpenVPNModule,
                              module.providerSelection != nil else {
                            return nil
                        }
                        return ($0.offset, module)
                    }

                // convert provider modules to ProviderModule of type .openVPN
                try ovpnPairs.forEach {
                    guard let selection = $0.module.providerSelection else {
                        return
                    }

                    var providerBuilder = ProviderModule.Builder()
                    providerBuilder.providerId = ProviderID(rawValue: selection.id.rawValue)
                    providerBuilder.providerModuleType = .openVPN
                    providerBuilder.entity = try selection.entity?.upgraded()

                    var options = OpenVPNProviderTemplate.Options()
                    options.credentials = $0.module.credentials
                    try providerBuilder.setOptions(options, for: .openVPN)
                    let provider = try providerBuilder.tryBuild()

                    // replace old module
                    builder.modules[$0.offset] = provider
                    builder.activeModulesIds.insert(provider.id)
                    builder.activeModulesIds.remove($0.module.id)
                }
#endif

                // set new version at the very least
                return try builder.tryBuild()
            default:
                return nil
            }
        } catch {
            pp_log_id(profile.id, .core, .error, "Unable to migrate profile \(profile.id): \(error)")
            return nil
        }
    }
}
