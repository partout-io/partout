// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(PartoutOpenVPN)

import Foundation
import PartoutCore
import PartoutOpenVPN

struct OpenVPNProviderResolver: ProviderModuleResolver {
    private let ctx: PartoutLoggerContext

    var moduleType: ModuleType {
        .openVPN
    }

    init(_ ctx: PartoutLoggerContext) {
        self.ctx = ctx
    }

    func resolved(from providerModule: ProviderModule, on deviceId: String) throws -> Module {
        try providerModule.compiled(
            ctx,
            withTemplate: OpenVPNProviderTemplate.self,
            onDevice: deviceId
        )
    }
}

#endif
