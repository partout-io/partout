//
//  Shared+Tunnel.swift
//  Partout
//
//  Created by Davide De Rosa on 3/26/24.
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

import Foundation
import Partout
import PartoutOpenVPN
import PartoutWireGuard

// MARK: - Implementations

extension Registry {
    static let shared = Registry(
        withKnown: true,
        allImplementations: [
            OpenVPNModule.Implementation(
                importer: StandardOpenVPNParser(),
                connectionBlock: {
                    try await OpenVPNConnection(
                        parameters: $0,
                        module: $1,
                        prng: PartoutConfiguration.platform.newPRNG(),
                        dns: PartoutConfiguration.platform.newDNSResolver(),
                        cachesURL: Demo.moduleURL(for: "OpenVPN")
                    )
                }
            ),
            WireGuardModule.Implementation(
                keyGenerator: StandardWireGuardKeyGenerator(),
                importer: StandardWireGuardParser(),
                validator: StandardWireGuardParser(),
                connectionBlock: {
                    try WireGuardConnection(
                        parameters: $0,
                        module: $1
                    )
                }
            )
        ]
    )
}

extension NEProtocolDecoder where Self == KeychainNEProtocolCoder {
    static var shared: Self {
        Demo.neProtocolCoder
    }
}
