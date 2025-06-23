//
//  LocalInterface.swift
//  Partout
//
//  Created by Davide De Rosa on 3/25/24.
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
import PartoutCore

extension WireGuard {

    /// The parameters of the local interface.
    public struct LocalInterface: BuildableType, Hashable, Codable, Sendable {

        /// The local private key.
        public let privateKey: Key

        /// The local addresses.
        public let addresses: [Subnet]

        /// The optional DNS settings.
        public let dns: DNSModule?

        /// The optional MTU.
        public let mtu: UInt16?

        public init(privateKey: Key, addresses: [Subnet], dns: DNSModule?, mtu: UInt16?) {
            self.privateKey = privateKey
            self.addresses = addresses
            self.dns = dns
            self.mtu = mtu
        }

        public func builder() -> Builder {
            var copy = Builder(privateKey: privateKey.rawValue)
            copy.addresses = addresses.map(\.rawValue)
            copy.dns = dns?.builder() ?? DNSModule.Builder()
            copy.mtu = mtu
            return copy
        }
    }
}

extension WireGuard.LocalInterface {
    public struct Builder: BuilderType, Hashable {
        public var privateKey: String

        public var addresses: [String]

        public var dns: DNSModule.Builder

        public var mtu: UInt16?

        public init(privateKey: String) {
            self.privateKey = privateKey
            dns = DNSModule.Builder()
            addresses = []
        }

        public init(keyGenerator: WireGuardKeyGenerator) {
            privateKey = keyGenerator.newPrivateKey()
            dns = DNSModule.Builder()
            addresses = []
        }

        public func tryBuild() throws -> WireGuard.LocalInterface {
            guard let validPrivateKey = WireGuard.Key(rawValue: privateKey) else {
                throw PartoutError.invalidFields(["privateKey": privateKey])
            }
            let validAddresses = try addresses.map {
                guard let addr = Subnet(rawValue: $0) else {
                    throw PartoutError.invalidFields(["addresses": $0])
                }
                return addr
            }
            return WireGuard.LocalInterface(
                privateKey: validPrivateKey,
                addresses: validAddresses,
                dns: try dns.tryBuild(),
                mtu: mtu
            )
        }
    }
}
