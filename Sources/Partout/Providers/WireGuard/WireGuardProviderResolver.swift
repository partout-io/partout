// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(PartoutWireGuard)

import PartoutCore
import PartoutWireGuard

struct WireGuardProviderResolver: ProviderModuleResolver {
    private let ctx: PartoutLoggerContext

    var moduleType: ModuleType {
        .wireGuard
    }

    init(_ ctx: PartoutLoggerContext) {
        self.ctx = ctx
    }

    func resolved(from providerModule: ProviderModule, on deviceId: String) throws -> Module {
        try providerModule.compiled(
            ctx,
            withTemplate: WireGuardProviderTemplate.self,
            onDevice: deviceId
        )
    }
}

#endif
