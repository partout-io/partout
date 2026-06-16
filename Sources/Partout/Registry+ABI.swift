// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Registry {
    typealias OpenVPNConnection = _OpenVPNConnectionV3
    typealias WireGuardConnection = _WireGuardConnectionV2

    private static let noCacheURL = URL(filePath: "")

    static func forImport(_ ctx: PartoutLoggerContext) -> Registry {
        forDaemon(ctx, cachesURL: noCacheURL)
    }

    static func forDaemon(_ ctx: PartoutLoggerContext, cachesURL: URL) -> Registry {
        let allImplementations = moduleImplementations(ctx, cachesURL: cachesURL)
        return Registry(
            withKnown: true,
            allImplementations: allImplementations
        )
    }
}

private extension Registry {
    static func moduleImplementations(
        _ ctx: PartoutLoggerContext,
        cachesURL: URL
    ) -> [ModuleImplementation] {
        var list: [ModuleImplementation] = []
#if PARTOUT_OPENVPN
        list.append(OpenVPNModule.Implementation(
            importerBlock: {
                StandardOpenVPNParser()
            },
            connectionBlock: { parameters, module in
                try OpenVPNConnection(
                    ctx,
                    parameters: parameters,
                    module: module,
                    cachesURL: cachesURL
                )
            }
        ))
#endif
#if PARTOUT_WIREGUARD
        list.append(WireGuardModule.Implementation(
            keyGenerator: StandardWireGuardKeyGenerator(),
            importerBlock: {
                StandardWireGuardParser()
            },
            validatorBlock: {
                StandardWireGuardParser()
            },
            connectionBlock: { parameters, module in
                try WireGuardConnection(
                    ctx,
                    parameters: parameters,
                    module: module
                )
            }
        ))
#endif
        return list
    }
}
