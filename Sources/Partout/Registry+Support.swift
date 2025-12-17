// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Registry {
    private static let knownHandlers: [ModuleHandler] = {
        var handlers: [ModuleHandler] = [
            DNSModule.moduleHandler,
            FilterModule.moduleHandler,
            HTTPProxyModule.moduleHandler,
            IPModule.moduleHandler,
            OnDemandModule.moduleHandler
        ]
#if PARTOUT_OPENVPN
        handlers.append(OpenVPNModule.moduleHandler)
#endif
#if PARTOUT_WIREGUARD
        handlers.append(WireGuardModule.moduleHandler)
#endif
        return handlers
    }()

    /// Returns a ``Registry`` with the known module handlers and resolvers and an empty device ID.
    public convenience init() {
        self.init(withKnown: true)
    }

    /// Returns a ``Registry`` that optionally includes the known module handlers and resolvers.
    public convenience init(
        withKnown: Bool,
        customHandlers: [ModuleHandler] = [],
        allImplementations: [ModuleImplementation] = [],
        resolvedModuleBlock: ResolvedModuleBlock? = nil
    ) {
        let handlers = withKnown ? Self.knownHandlers + customHandlers : customHandlers
        self.init(
            allHandlers: handlers,
            allImplementations: allImplementations,
            postDecodeBlock: Self.migratedProfile,
            resolvedModuleBlock: resolvedModuleBlock
        )
    }
}

private extension Registry {

    @Sendable
    static func migratedProfile(_ profile: Profile) -> Profile? {
        do {
            switch profile.version {
            case nil:
                // Set new version at the very least
                let builder = profile.builder(withNewId: false, forUpgrade: true)
                return try builder.build()
            default:
                return nil
            }
        } catch {
            pp_log_id(profile.id, .core, .error, "Unable to migrate profile \(profile.id): \(error)")
            return nil
        }
    }
}
