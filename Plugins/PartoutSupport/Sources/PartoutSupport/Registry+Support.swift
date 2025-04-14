//
//  Registry+Support.swift
//  Partout
//
//  Created by Davide De Rosa on 2/24/24.
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
import PartoutAPI
import PartoutCore

extension Registry {
    private static let knownHandlers = [
        DNSModule.moduleHandler,
        FilterModule.moduleHandler,
        HTTPProxyModule.moduleHandler,
        IPModule.moduleHandler,
        OnDemandModule.moduleHandler,
        OpenVPNModule.moduleHandler,
        ProviderModule.moduleHandler,
        WireGuardModule.moduleHandler
    ]

    private static let knownProviderResolvers: [ProviderModuleResolver] = [
        OpenVPNProviderResolver(),
        WireGuardProviderResolver()
    ]

    public convenience init() {
        self.init(withKnown: true)
    }

    public convenience init(
        withKnown: Bool,
        customHandlers: [ModuleHandler] = [],
        allProviderResolvers: [ProviderModuleResolver]? = nil,
        allImplementations: [ModuleImplementation]? = nil
    ) {
        let handlers = withKnown ? Self.knownHandlers + customHandlers : customHandlers
        let allProviderResolvers = allProviderResolvers ?? (withKnown ? Self.knownProviderResolvers : [])

        let mappedResolvers = allProviderResolvers
            .reduce(into: [:]) {
                $0[$1.moduleType] = $1
            }

        self.init(
            allHandlers: handlers,
            allImplementations: allImplementations ?? [],
            postDecodeBlock: Self.migratedProfile,
            resolvedModuleBlock: { module, profile in
                do {
                    if let profile {
                        profile.assertSingleActiveProviderModule()
                        guard profile.isActiveModule(withId: module.id) else {
                            return module
                        }
                    }
                    guard let providerModule = module as? ProviderModule else {
                        return module
                    }
                    guard let resolver = mappedResolvers[providerModule.providerModuleType] else {
                        return module
                    }
                    return try resolver.resolved(from: providerModule)
                } catch {
                    pp_log(.core, .error, "Unable to resolve module: \(error)")
                    throw error as? PartoutError ?? PartoutError(.Support.corruptProviderModule, error)
                }
            }
        )
    }
}

private extension Profile {
    func resolvingProviderModules(with resolvers: [ModuleType: ProviderModuleResolver]) throws -> Self {
        do {
            var copy = builder()
            copy.assertSingleActiveProviderModule()
            copy.modules = try copy.modules.map {
                guard activeModulesIds.contains($0.id) else {
                    return $0
                }
                guard let providerModule = $0 as? ProviderModule else {
                    return $0
                }
                guard let resolver = resolvers[providerModule.providerModuleType] else {
                    return $0
                }
                return try resolver.resolved(from: providerModule)
            }
            return try copy.tryBuild()
        } catch {
            throw error as? PartoutError ?? PartoutError(.Support.corruptProviderModule, error)
        }
    }
}
