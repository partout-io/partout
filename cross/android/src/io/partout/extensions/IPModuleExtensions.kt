// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.IPModule
import io.partout.models.IPSettings
import io.partout.models.Route
import java.net.Inet6Address

internal fun Iterable<IPModule>.effectiveIPModule(): IPModule? {
    var current: IPModule? = null
    for (module in this) {
        val previous = current
        current = module.copy(
            ipv4 = previous?.ipv4.merge(module.ipv4, VpnAddressFamily.IPv4),
            ipv6 = previous?.ipv6.merge(module.ipv6, VpnAddressFamily.IPv6),
            mtu = module.mtu?.takeIf { it > 0 } ?: previous?.mtu
        )
    }
    return current
}

private fun IPSettings?.merge(next: IPSettings?, family: VpnAddressFamily): IPSettings? {
    if (next == null) return this
    if (this == null) return next
    val removesDefault = next.excludedRoutes.any { it.isDefault(family) }
    return IPSettings(
        subnets = subnets + next.subnets,
        includedRoutes = (includedRoutes + next.includedRoutes).filterNot {
            removesDefault && it.isDefault(family)
        },
        excludedRoutes = (excludedRoutes + next.excludedRoutes).filterNot {
            removesDefault && it.isDefault(family)
        }
    )
}

private fun Route.isDefault(family: VpnAddressFamily): Boolean =
    destinationPrefix(family)?.let { it.prefixLength == 0 && it.address.isAnyLocalAddress } == true

internal val IPModule.isDefaultGateway: Boolean
    get() = ipv4?.includedRoutes?.any { it.isDefault(VpnAddressFamily.IPv4) } == true ||
        ipv6?.includedRoutes?.any { it.isDefault(VpnAddressFamily.IPv6) } == true

internal fun IPModule.excludesHostRoute(hostRoute: VpnSubnet, supportsExclusions: Boolean): Boolean {
    if (!supportsExclusions) return false
    val family = if (hostRoute.address is Inet6Address) VpnAddressFamily.IPv6 else VpnAddressFamily.IPv4
    if (hostRoute.prefixLength != family.maxPrefixLength) return false
    val settings = if (family == VpnAddressFamily.IPv6) ipv6 else ipv4
    return settings?.excludedRoutes?.any { it.destinationPrefix(family) == hostRoute } == true
}
