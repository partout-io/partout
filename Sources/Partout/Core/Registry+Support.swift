// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(PartoutOpenVPN)
import PartoutOpenVPN
#endif
#if canImport(PartoutWireGuard)
import PartoutWireGuard
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
#if canImport(PartoutOpenVPN)
        handlers.append(OpenVPNModule.moduleHandler)
#endif
#if canImport(PartoutWireGuard)
        handlers.append(WireGuardModule.moduleHandler)
#endif
        return handlers
    }()

    private static let knownProviderResolvers: [ProviderModuleResolver] = {
        var resolvers: [ProviderModuleResolver] = []
#if canImport(PartoutOpenVPN)
        resolvers.append(OpenVPNProviderResolver(.global))
#endif
#if canImport(PartoutWireGuard)
        resolvers.append(WireGuardProviderResolver(.global))
#endif
        return resolvers
    }()

    /// Returns a ``/PartoutCore/Registry`` with the known module handlers and resolvers and an empty device ID.
    public convenience init() {
        self.init(deviceId: "", withKnown: true)
    }

    /// Returns a ``/PartoutCore/Registry`` that optionally includes the known module handlers and resolvers.
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
                try Self.resolvedModule($1, in: $2, with: mappedResolvers, on: $0)
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
            return try resolver.resolved(from: providerModule, on: deviceId)
        } catch {
            pp_log_id(profile?.id, .core, .error, "Unable to resolve module: \(error)")
            throw error as? PartoutError ?? PartoutError(.Providers.corruptModule, error)
        }
    }
}
