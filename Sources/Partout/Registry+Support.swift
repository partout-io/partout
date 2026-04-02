// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Registry {
    private static let knownHandlers: [ModuleHandler] = [
        DNSModule.moduleHandler,
        HTTPProxyModule.moduleHandler,
        IPModule.moduleHandler,
        OnDemandModule.moduleHandler,
        OpenVPNModule.moduleHandler,
        WireGuardModule.moduleHandler
    ]

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
            resolvedModuleBlock: resolvedModuleBlock
        )
    }
}
