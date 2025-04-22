//
//  IPModule+NE.swift
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
import NetworkExtension
import PartoutCore

extension IPModule: NESettingsApplying {
    public func apply(to settings: inout NEPacketTunnelNetworkSettings) {
        if let ipv4 {
            settings.ipv4Settings = settings.ipv4Settings?.merged(with: ipv4) ?? ipv4.neIPv4Settings
            pp_log(.ne, .info, "\t\tIPv4: \(settings.ipv4Settings?.debugDescription ?? "none")")
        }
        if let ipv6 {
            settings.ipv6Settings = settings.ipv6Settings?.merged(with: ipv6) ?? ipv6.neIPv6Settings
            pp_log(.ne, .info, "\t\tIPv6: \(settings.ipv6Settings?.debugDescription ?? "none"))")
        }
        if let mtu, mtu > 0 {
            settings.mtu = mtu as NSNumber
            pp_log(.ne, .info, "\t\tMTU: \(mtu)")
        }
    }
}

private extension IPSettings {
    var neIPv4Settings: NEIPv4Settings {
        let ne = NEIPv4Settings(
            addresses: subnet.map {
                [$0.address.rawValue]
            } ?? [],
            subnetMasks: subnet.map {
                [$0.ipv4Mask]
            } ?? []
        )
        ne.includedRoutes = includedRoutes.map(\.neIPv4Route)
        ne.excludedRoutes = excludedRoutes.map(\.neIPv4Route)
        return ne
    }
}

private extension Route {
    var neIPv4Route: NEIPv4Route {
        let route = destination.map {
            NEIPv4Route(destinationAddress: $0.address.rawValue, subnetMask: $0.ipv4Mask)
        } ?? NEIPv4Route.default()
        route.gatewayAddress = gateway?.rawValue
        return route
    }
}

private extension IPSettings {
    var neIPv6Settings: NEIPv6Settings {
        let ne = NEIPv6Settings(
            addresses: subnet.map {
                [$0.address.rawValue]
            } ?? [],
            networkPrefixLengths: subnet.map {
                [$0.prefixLength as NSNumber]
            } ?? []
        )
        ne.includedRoutes = includedRoutes.map(\.neIPv6Route)
        ne.excludedRoutes = excludedRoutes.map(\.neIPv6Route)
        return ne
    }
}

private extension Route {
    var neIPv6Route: NEIPv6Route {
        let route = destination.map {
            NEIPv6Route(destinationAddress: $0.address.rawValue, networkPrefixLength: $0.prefixLength as NSNumber)
        } ?? NEIPv6Route.default()
        route.gatewayAddress = gateway?.rawValue
        return route
    }
}

private extension NEIPv4Settings {
    func merged(with ipv4: IPSettings) -> Self {
        var newAddresses = addresses
        var newMasks = subnetMasks
        if let subnet = ipv4.subnet {
            newAddresses.append(subnet.address.rawValue)
            newMasks.append(subnet.ipv4Mask)
        }
        let newSettings = Self(addresses: newAddresses, subnetMasks: newMasks)
        let moreIncluded = ipv4.includedRoutes.map(\.neIPv4Route)
        let moreExcluded = ipv4.excludedRoutes.map(\.neIPv4Route)

        newSettings.includedRoutes = (includedRoutes ?? []) + moreIncluded
        newSettings.excludedRoutes = (excludedRoutes ?? []) + moreExcluded
        if moreExcluded.contains(.default()) {
            newSettings.includedRoutes?.removeAll {
                $0 == .default()
            }
            newSettings.excludedRoutes?.removeAll {
                $0 == .default()
            }
        }

        return newSettings
    }
}

private extension NEIPv6Settings {
    func merged(with ipv6: IPSettings) -> Self {
        var newAddresses = addresses
        var newPrefixLengths = networkPrefixLengths
        if let subnet = ipv6.subnet {
            newAddresses.append(subnet.address.rawValue)
            newPrefixLengths.append(subnet.prefixLength as NSNumber)
        }
        let newSettings = Self(addresses: newAddresses, networkPrefixLengths: newPrefixLengths)
        let moreIncluded = ipv6.includedRoutes.map(\.neIPv6Route)
        let moreExcluded = ipv6.excludedRoutes.map(\.neIPv6Route)

        newSettings.includedRoutes = (includedRoutes ?? []) + moreIncluded
        newSettings.excludedRoutes = (excludedRoutes ?? []) + moreExcluded
        if moreExcluded.contains(.default()) {
            newSettings.includedRoutes?.removeAll {
                $0 == .default()
            }
            newSettings.excludedRoutes?.removeAll {
                $0 == .default()
            }
        }

        return newSettings
    }
}
