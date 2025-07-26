//
//  OpenVPNConnection+Default.swift
//  Partout
//
//  Created by Davide De Rosa on 3/15/24.
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

internal import _PartoutVendorsPortable
import Foundation
import PartoutCore
import PartoutOpenVPN

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
#if OPENVPN_WRAPPED_NATIVE
                    try TLSWrapper.native(with: $0).tls
#else
                    try TLSWrapper.legacy(with: $0).tls
#endif
                },
                dpFactory: {
                    let wrapper: DataPathWrapper
#if OPENVPN_WRAPPED_NATIVE
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
