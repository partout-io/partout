//
//  Shared+App.swift
//  Partout
//
//  Created by Davide De Rosa on 2/25/24.
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

extension Demo.Log {
    static let appURL = Demo.cachesURL.appending(component: "app.log")
}

// MARK: - Implementations

extension Registry {
    static let shared = Registry()
}

extension Tunnel {
    static let shared: Tunnel = {
#if targetEnvironment(simulator)
        let strategy = FakeTunnelStrategy()
        return Tunnel(strategy: strategy) { _ in
            SharedTunnelEnvironment()
        }
#else
        let strategy = NETunnelStrategy(
            .global,
            bundleIdentifier: Demo.tunnelBundleIdentifier,
            coder: Demo.neProtocolCoder
        )
        return Tunnel(.global, strategy: strategy) {
            NETunnelEnvironment(strategy: strategy, profileId: $0)
        }
#endif
    }()
}
