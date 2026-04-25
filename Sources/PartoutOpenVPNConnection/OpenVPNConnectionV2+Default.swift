// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPNConnectionV2 {
    public init(
        _ ctx: PartoutLoggerContext,
        parameters: ConnectionParameters,
        module: OpenVPNModule,
        cachesURL: URL,
        options baseOptions: OpenVPNConnection.Options = .init()
    ) throws {
        guard let configuration = module.configuration else {
            fatalError("Creating session without OpenVPN configuration?")
        }
        pp_log(ctx, .openvpn, .notice, "OpenVPN: Using cross-platform connection V2")

        // Override options with feature flags
        var options = baseOptions
        options.withLoopsV2 = true
        options.withFlushDataBeforeControl = true

        // Hardcode portable implementations
        let prng = PlatformPRNG()
        let dns = SimpleDNSResolver {
            POSIXDNSStrategy(hostname: $0)
        }
        let sessionFactory = {
            try await OpenVPNSession(
                ctx,
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
