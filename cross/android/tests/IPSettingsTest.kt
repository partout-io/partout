// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
package io.partout

import io.partout.extensions.effectiveIPModule
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
        println("IP merging and default-route removal passed")
    }
}
