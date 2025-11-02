// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
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
        false
#else
        true // macOS, tvOS
#endif
    }
}
