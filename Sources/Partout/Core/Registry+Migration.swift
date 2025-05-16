//
//  Registry+Migration.swift
//  Partout
//
//  Created by Davide De Rosa on 3/26/25.
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

#if canImport(_PartoutOpenVPN)
import _PartoutOpenVPN
#endif
import Foundation
import PartoutCore
import PartoutProviders

extension Registry {

    @Sendable
    static func migratedProfile(_ profile: Profile) -> Profile? {
        do {
            switch profile.version {
            case nil:
                var builder = profile.builder(withNewId: false, forUpgrade: true)

#if canImport(_PartoutOpenVPN)
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
