// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
internal import _PartoutOpenVPNLegacy_ObjC
import PartoutCore
import PartoutOpenVPN
#endif

extension LegacyOpenVPNConnection {
    public init(
        _ ctx: PartoutLoggerContext,
        parameters: ConnectionParameters,
        module: OpenVPNModule,
        prng: PRNGProtocol,
        dns: DNSResolver,
        options: OpenVPN.ConnectionOptions = .init(),
        cachesURL: URL
    ) throws {
        guard let configuration = module.configuration else {
            fatalError("Creating session without OpenVPN configuration?")
        }
        let tlsFactory = { @Sendable in
            OSSLTLSBox()
        }
        let cryptoFactory = { @Sendable in
            let seed = prng.safeData(length: 64)
            guard let box = OSSLCryptoBox(seed: seed) else {
                fatalError("Unable to create OSSLCryptoBox")
            }
            return box
        }
        let sessionFactory = {
            try await OpenVPNSession(
                ctx,
                configuration: configuration,
                credentials: module.credentials,
                prng: prng,
                tlsFactory: tlsFactory,
                cryptoFactory: cryptoFactory,
                cachesURL: cachesURL,
                options: options
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
