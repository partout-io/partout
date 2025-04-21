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

import _PartoutOpenVPN
import _PartoutWireGuard
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
            pp_log(.core, .error, "Unable to resolve module: \(error)")
            throw error as? PartoutError ?? PartoutError(.API.corruptProviderModule, error)
        }
    }
}
