//
//  OnDemandModule+Support.swift
//  Partout
//
//  Created by Davide De Rosa on 1/29/25.
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
import NetworkExtension
import PartoutCore
#if os(iOS)
import UIKit
#endif

extension OnDemandModule {
    public static var supportsCellular: Bool {
#if targetEnvironment(simulator)
        true
#else
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else {
            return false
        }
        var isFound = false
        var cursor = addrs?.pointee
        while let ifa = cursor {
            let name = String(cString: ifa.ifa_name)
            if name == "pdp_ip0" {
                isFound = true
                break
            }
            cursor = ifa.ifa_next?.pointee
        }
        freeifaddrs(addrs)
        return isFound
#endif
    }

    public static var supportsEthernet: Bool {
#if os(iOS)
        // TODO: #1119/passepartout, iPad Pro supports Ethernet via USB-C, but NE offers no way to match it
        // UIDevice.current.userInterfaceIdiom == .pad
        false
#else
        true // macOS, tvOS
#endif
    }
}
