// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import android.os.Build
import android.util.Log
import io.partout.extensions.VpnAddressFamily
import io.partout.extensions.VpnSubnet
import io.partout.extensions.destinationPrefix
import io.partout.models.IPModule
import io.partout.models.IPSettings
import io.partout.models.Route

internal class IPModuleApplying(
    private val module: IPModule
): VpnServiceApplying {
    override fun apply(logTag: String, builder: VpnService.Builder): Boolean {
        val addedIPv4Address = module.ipv4?.apply(logTag, builder, family = VpnAddressFamily.IPv4) == true
        val addedIPv6Address = module.ipv6?.apply(logTag, builder, family = VpnAddressFamily.IPv6) == true
        module.mtu?.takeIf { it > 0 }?.let {
            Log.i(logTag, "IP: MTU = $it")
            builder.setMtu(it)
        }
        return addedIPv4Address || addedIPv6Address
    }
}

private fun IPSettings.apply(logTag: String, builder: VpnService.Builder, family: VpnAddressFamily): Boolean {
    val addedAddress = subnets.fold(false) { addedAddress, rawSubnet ->
        rawSubnet.addAddress(logTag, builder, family = family) || addedAddress
    }
    includedRoutes.forEach { route ->
        route.apply(logTag, builder, isExcluded = false, family = family)
    }
    excludedRoutes.forEach { route ->
        route.apply(logTag, builder, isExcluded = true, family = family)
    }
    return addedAddress
}

private fun String.addAddress(logTag: String, builder: VpnService.Builder, family: VpnAddressFamily): Boolean {
    val subnet = VpnSubnet.parse(this, family = family, isInterfaceAddress = true)
    if (subnet == null) {
        Log.w(logTag, "IP: Ignoring invalid subnet '$this'")
        return false
    }
    Log.i(logTag, "IP: Address = ${subnet.cidr}")
    return runCatching {
        builder.addAddress(subnet)
    }.onFailure {
        Log.w(logTag, "IP: Unable to add address '$this'", it)
    }.isSuccess
}

private fun Route.apply(logTag: String, builder: VpnService.Builder, isExcluded: Boolean, family: VpnAddressFamily) {
    val routeType = if (isExcluded) "excluded" else "included"
    val prefix = destinationPrefix(family) ?: run {
        Log.w(logTag, "IP: Ignoring invalid $routeType route '$this'")
        return
    }
    gateway?.let {
        Log.i(logTag, "IP: Route gateway is ignored on Android VPNs: $it")
    }
    if (isExcluded) {
        prefix.excludeRoute(logTag, builder, route = this)
    } else {
        prefix.includeRoute(logTag, builder, route = this)
    }
}

private fun VpnSubnet.includeRoute(logTag: String, builder: VpnService.Builder, route: Route) {
    Log.i(logTag, "IP: Include route $cidr")
    runCatching {
        builder.addRoute(this)
    }.onFailure {
        Log.w(logTag, "IP: Unable to add route '$route'", it)
    }
}

private fun VpnSubnet.excludeRoute(logTag: String, builder: VpnService.Builder, route: Route) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
        Log.i(logTag, "IP: Cannot exclude route before API 33: $cidr")
        return
    }
    Log.i(logTag, "IP: Exclude route $cidr")
    builder.tryExcludeRoute(this)?.let {
        Log.w(logTag, "IP: Unable to exclude route '$route'", it)
    }
}
