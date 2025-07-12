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

#if canImport(_PartoutOpenVPNCore)
import _PartoutOpenVPNCore
#endif
#if canImport(_PartoutWireGuardCore)
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
#if canImport(_PartoutOpenVPNCore)
        handlers.append(OpenVPNModule.moduleHandler)
#endif
#if canImport(_PartoutWireGuardCore)
        handlers.append(WireGuardModule.moduleHandler)
#endif
        return handlers
    }()

    private static let knownProviderResolvers: [ProviderModuleResolver] = {
        var resolvers: [ProviderModuleResolver] = []
#if canImport(_PartoutOpenVPNCore)
        resolvers.append(OpenVPNProviderResolver(.global))
#endif
#if canImport(_PartoutWireGuardCore)
        resolvers.append(WireGuardProviderResolver(.global))
#endif
        return resolvers
    }()

    public convenience init() {
        self.init(deviceId: "", withKnown: true)
    }

    public convenience init(
        deviceId: String,
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
            deviceId: deviceId,
            allHandlers: handlers,
            allImplementations: allImplementations,
            postDecodeBlock: Self.migratedProfile,
            resolvedModuleBlock: {
                try Self.resolvedModule($0, in: $1, with: mappedResolvers, on: deviceId)
            }
        )
    }
}

private extension Registry {

    @Sendable
    static func resolvedModule(
        _ module: Module,
        in profile: Profile?,
        with resolvers: [ModuleType: ProviderModuleResolver],
        on deviceId: String
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
            return try resolver.resolved(from: providerModule, deviceId: deviceId)
        } catch {
            pp_log_id(profile?.id, .core, .error, "Unable to resolve module: \(error)")
            throw error as? PartoutError ?? PartoutError(.Providers.corruptProviderModule, error)
        }
    }
}
