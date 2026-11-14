// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
package io.partout

import io.partout.extensions.effectiveIPModule
import io.partout.extensions.excludesHostRoute
import io.partout.extensions.VpnSubnet
import io.partout.extensions.isDefaultGateway
import io.partout.models.IPModule
import io.partout.models.IPSettings
import io.partout.models.Route

object IPSettingsTest {
    @JvmStatic
    fun main(args: Array<String>) {
        val vpn = IPModule("vpn", ipv4 = IPSettings(listOf("10.0.0.2/24"), listOf(Route()), emptyList()), mtu = 1400)
        val override = IPModule("profile", ipv4 = IPSettings(emptyList(), listOf(Route(destination = "192.168.0.0/16")), listOf(Route())), mtu = 0)
        val resolved = checkNotNull(listOf(vpn, override).effectiveIPModule())
        check(!resolved.isDefaultGateway)
        check(resolved.ipv4?.subnets == vpn.ipv4?.subnets)
        check(resolved.ipv4?.includedRoutes == override.ipv4?.includedRoutes)
        check(resolved.ipv4?.excludedRoutes?.isEmpty() == true)
        check(resolved.mtu == 1400)
        check(listOf(vpn, override, vpn.copy(mtu = 1300)).effectiveIPModule()?.isDefaultGateway == true)
        check(listOf(vpn, override, vpn.copy(mtu = 1300)).effectiveIPModule()?.mtu == 1300)
        val exclusions = IPModule(
            "exclusions",
            ipv4 = IPSettings(emptyList(), emptyList(), listOf(
                Route(destination = "1.1.1.1/32"),
                Route(destination = "8.8.8.0/24")
            )),
            ipv6 = IPSettings(emptyList(), emptyList(), listOf(
                Route(destination = "2001:db8::53/128")
            ))
        )
        val merged = checkNotNull(listOf(vpn, exclusions).effectiveIPModule())
        for (server in listOf("1.1.1.1", "2001:0db8:0:0:0:0:0:53")) {
            val hostRoute = checkNotNull(VpnSubnet.parse(server))
            check(merged.excludesHostRoute(hostRoute, supportsExclusions = true))
            check(!merged.excludesHostRoute(hostRoute, supportsExclusions = false))
        }
        // A broader exclusion must not suppress a more-specific DNS inclusion.
        for (server in listOf("8.8.8.8", "9.9.9.9", "2001:db8::54")) {
            check(!merged.excludesHostRoute(checkNotNull(VpnSubnet.parse(server)), true))
        }
        check(!vpn.excludesHostRoute(checkNotNull(VpnSubnet.parse("1.1.1.1")), true))
        println("IP merging, default-route removal, and DNS host exclusions passed")
    }
}
