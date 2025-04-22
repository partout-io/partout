//
//  WireGuard+Configuration.swift
//  Partout
//
//  Created by Davide De Rosa on 11/23/21.
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

    /// Represents a WireGuard configuration.
    public struct Configuration: BuildableType, Hashable, Codable, Sendable {

        /// The local interface.
        public let interface: LocalInterface

        /// The peers.
        public let peers: [RemoteInterface]

        public func builder() -> Builder {
            Builder(
                interface: interface.builder(),
                peers: peers.map {
                    $0.builder()
                }
            )
        }
    }
}

extension WireGuard.Configuration {
    public struct Builder: BuilderType, Hashable {
        public var interface: WireGuard.LocalInterface.Builder

        public var peers: [WireGuard.RemoteInterface.Builder]

        public init(privateKey: String) {
            self.init(
                interface: WireGuard.LocalInterface.Builder(privateKey: privateKey),
                peers: []
            )
        }

        public init(keyGenerator: WireGuardKeyGenerator) {
            self.init(
                interface: WireGuard.LocalInterface.Builder(keyGenerator: keyGenerator),
                peers: []
            )
        }

        public init(interface: WireGuard.LocalInterface.Builder, peers: [WireGuard.RemoteInterface.Builder]) {
            self.interface = interface
            self.peers = peers
        }

        public func tryBuild() throws -> WireGuard.Configuration {
            return WireGuard.Configuration(
                interface: try interface.tryBuild(),
                peers: try peers.map {
                    try $0.tryBuild()
                }
            )
        }
    }
}
