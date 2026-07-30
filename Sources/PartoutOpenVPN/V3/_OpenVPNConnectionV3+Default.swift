// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C

extension _OpenVPNConnectionV3 {
    public init(
        _ ctx: PartoutLoggerContext,
        parameters: ConnectionParameters,
        module: OpenVPNModule,
        cachesURL: URL,
        options: OpenVPNConnectionOptions = .init()
    ) throws {
        guard let configuration = module.configuration else {
            fatalError("Creating session without OpenVPN configuration?")
        }
        pp_log(ctx, .openvpn, .notice, "OpenVPN: Using v3 connection")

        // Hardcode portable implementations
        let prng = PlatformPRNG()
        let dns = parameters.controller as? DNSResolver ?? SimpleDNSResolver {
            POSIXDNSStrategy(hostname: $0, flags: $1)
        }
        let sessionFactory = {
            try OpenVPNSessionV3(
                ctx,
                fnt: options.backend.functionTable,
                configuration: configuration,
                credentials: module.credentials,
                prng: prng,
                cachesURL: cachesURL,
                options: options,
                tlsFactory: {
                    try TLSWrapper.native(with: $0).tls
                },
                dpFactory: {
                    try DataPathWrapper.native(with: $0, prf: $1, prng: $2).dataPath
                }
            )
        }

        try self.init(
            ctx,
            parameters: parameters,
            module: module,
            prng: prng,
            dns: dns,
            sessionFactory: sessionFactory
        )
    }
}
