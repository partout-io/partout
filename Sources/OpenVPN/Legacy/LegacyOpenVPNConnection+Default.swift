//
//  LegacyOpenVPNConnection+Default.swift
//  Partout
//
//  Created by Davide De Rosa on 1/10/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

internal import _PartoutOpenVPNLegacy_ObjC
import Foundation
import PartoutCore
import PartoutOpenVPN

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
