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

#if canImport(_PartoutOpenVPN)
import _PartoutOpenVPNCore
#endif
#if canImport(_PartoutWireGuard)
import _PartoutWireGuardCore
#endif
import Foundation
import PartoutCore
import PartoutProviders

extension Registry {
    private static let knownHandlers: [ModuleHandler] = {
        var handlers: [ModuleHandler] = [
            DNSModule.moduleHandler,
            FilterModule.moduleHandler,
            HTTPProxyModule.moduleHandler,
            IPModule.moduleHandler,
            OnDemandModule.moduleHandler,
            ProviderModule.moduleHandler
        ]
#if canImport(_PartoutOpenVPN)
        handlers.append(OpenVPNModule.moduleHandler)
#endif
#if canImport(_PartoutWireGuard)
        handlers.append(WireGuardModule.moduleHandler)
#endif
        return handlers
    }()

    private static let knownProviderResolvers: [ProviderModuleResolver] = {
        var resolvers: [ProviderModuleResolver] = []
#if canImport(_PartoutOpenVPN)
        resolvers.append(OpenVPNProviderResolver(.global))
#endif
#if canImport(_PartoutWireGuard)
        resolvers.append(WireGuardProviderResolver(.global))
#endif
        return resolvers
    }()

    public convenience init() {
        self.init(withKnown: true)
    }

    public convenience init(
        withKnown: Bool,
        customHandlers: [ModuleHandler] = [],
        customProviderResolvers: [ProviderModuleResolver] = [],
        allImplementations: [ModuleImplementation] = []
    ) {
        let handlers = withKnown ? Self.knownHandlers + customHandlers : customHandlers
        let resolvers = withKnown ? Self.knownProviderResolvers + customProviderResolvers : customProviderResolvers

        let mappedResolvers = resolvers
            .reduce(into: [:]) {
                $0[$1.moduleType] = $1
            }

        self.init(
            allHandlers: handlers,
            allImplementations: allImplementations,
            postDecodeBlock: Self.migratedProfile,
            resolvedModuleBlock: {
                try Self.resolvedModule($0, in: $1, with: mappedResolvers)
            }
        )
    }
}

private extension Registry {

    @Sendable
    static func resolvedModule(
        _ module: Module,
        in profile: Profile?,
        with resolvers: [ModuleType: ProviderModuleResolver]
    ) throws -> Module {
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
            guard let resolver = resolvers[providerModule.providerModuleType] else {
                return module
            }
            return try resolver.resolved(from: providerModule)
        } catch {
            pp_log_id(profile?.id, .core, .error, "Unable to resolve module: \(error)")
            throw error as? PartoutError ?? PartoutError(.Providers.corruptProviderModule, error)
        }
    }
}
