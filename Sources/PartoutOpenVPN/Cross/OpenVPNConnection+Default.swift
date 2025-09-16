// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

extension OpenVPNConnection {
    public init(
        _ ctx: PartoutLoggerContext,
        parameters: ConnectionParameters,
        module: OpenVPNModule,
        cachesURL: URL,
        options: OpenVPN.ConnectionOptions = .init()
    ) throws {
        guard let configuration = module.configuration else {
            fatalError("Creating session without OpenVPN configuration?")
        }
#if OPENVPN_WRAPPER_NATIVE
        pp_log(ctx, .openvpn, .notice, "OpenVPN: Using cross-platform connection")
#else
        pp_log(ctx, .openvpn, .notice, "OpenVPN: Using wrapped legacy connection")
#endif

        // hardcode portable implementations
        let prng = PlatformPRNG()
        let dns = SimpleDNSResolver {
            POSIXDNSStrategy(hostname: $0)
        }

        // native: Swift/C
        // legacy: Swift/ObjC
        let sessionFactory = {
            try await OpenVPNSession(
                ctx,
                configuration: configuration,
                credentials: module.credentials,
                prng: prng,
                cachesURL: cachesURL,
                options: options,
                tlsFactory: {
#if OPENVPN_WRAPPER_NATIVE
                    try TLSWrapper.native(with: $0).tls
#else
                    try TLSWrapper.legacy(with: $0).tls
#endif
                },
                dpFactory: {
                    let wrapper: DataPathWrapper
#if OPENVPN_WRAPPER_NATIVE
                    wrapper = try .native(with: $0, prf: $1, prng: $2)
#else
                    wrapper = try .legacy(with: $0, prf: $1, prng: $2)
#endif
                    return wrapper.dataPath
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
