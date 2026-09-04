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
    override fun apply(logTag: String, builder: VpnService.Builder, logsPrivateData: Boolean): Boolean {
        val addedIPv4Address = module.ipv4?.apply(
            logTag,
            builder,
            family = VpnAddressFamily.IPv4,
            logsPrivateData = logsPrivateData
        ) == true
        val addedIPv6Address = module.ipv6?.apply(
            logTag,
            builder,
            family = VpnAddressFamily.IPv6,
            logsPrivateData = logsPrivateData
        ) == true
        module.mtu?.takeIf { it > 0 }?.let {
            Log.i(logTag, "IP: MTU = $it")
            builder.setMtu(it)
        }
        return addedIPv4Address || addedIPv6Address
    }
}

private fun IPSettings.apply(
    logTag: String,
    builder: VpnService.Builder,
    family: VpnAddressFamily,
    logsPrivateData: Boolean
): Boolean {
    val addedAddress = subnets.fold(false) { addedAddress, rawSubnet ->
        rawSubnet.addAddress(
            logTag,
            builder,
            family = family,
            logsPrivateData = logsPrivateData
        ) || addedAddress
    }
    includedRoutes.forEach { route ->
        route.apply(
            logTag,
            builder,
            isExcluded = false,
            family = family,
            logsPrivateData = logsPrivateData
        )
    }
    excludedRoutes.forEach { route ->
        route.apply(
            logTag,
            builder,
            isExcluded = true,
            family = family,
            logsPrivateData = logsPrivateData
        )
    }
    return addedAddress
}

private fun String.addAddress(
    logTag: String,
    builder: VpnService.Builder,
    family: VpnAddressFamily,
    logsPrivateData: Boolean
): Boolean {
    val subnet = VpnSubnet.parse(this, family = family, isInterfaceAddress = true)
    if (subnet == null) {
        Log.w(logTag, "IP: Ignoring invalid subnet '${sensitiveDescription(logsPrivateData)}'")
        return false
    }
    Log.i(logTag, "IP: Address = ${subnet.cidr.sensitiveDescription(logsPrivateData)}")
    return runCatching {
        builder.addAddress(subnet)
    }.onFailure {
        val message = "IP: Unable to add address '${sensitiveDescription(logsPrivateData)}'"
        if (logsPrivateData) Log.w(logTag, message, it) else Log.w(logTag, message)
    }.isSuccess
}

private fun Route.apply(
    logTag: String,
    builder: VpnService.Builder,
    isExcluded: Boolean,
    family: VpnAddressFamily,
    logsPrivateData: Boolean
) {
    val routeType = if (isExcluded) "excluded" else "included"
    val prefix = destinationPrefix(family) ?: run {
        Log.w(logTag, "IP: Ignoring invalid $routeType route '${sensitiveDescription(logsPrivateData)}'")
        return
    }
    gateway?.let {
        Log.i(logTag, "IP: Route gateway is ignored on Android VPNs: ${it.sensitiveDescription(logsPrivateData)}")
    }
    if (isExcluded) {
        prefix.excludeRoute(logTag, builder, route = this, logsPrivateData = logsPrivateData)
    } else {
        prefix.includeRoute(logTag, builder, route = this, logsPrivateData = logsPrivateData)
    }
}

private fun VpnSubnet.includeRoute(
    logTag: String,
    builder: VpnService.Builder,
    route: Route,
    logsPrivateData: Boolean
) {
    Log.i(logTag, "IP: Include route ${cidr.sensitiveDescription(logsPrivateData)}")
    runCatching {
        builder.addRoute(this)
    }.onFailure {
        val message = "IP: Unable to add route '${route.sensitiveDescription(logsPrivateData)}'"
        if (logsPrivateData) Log.w(logTag, message, it) else Log.w(logTag, message)
    }
}

private fun VpnSubnet.excludeRoute(
    logTag: String,
    builder: VpnService.Builder,
    route: Route,
    logsPrivateData: Boolean
) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
        Log.i(logTag, "IP: Cannot exclude route before API 33: ${cidr.sensitiveDescription(logsPrivateData)}")
        return
    }
    Log.i(logTag, "IP: Exclude route ${cidr.sensitiveDescription(logsPrivateData)}")
    builder.tryExcludeRoute(this)?.let {
        val message = "IP: Unable to exclude route '${route.sensitiveDescription(logsPrivateData)}'"
        if (logsPrivateData) Log.w(logTag, message, it) else Log.w(logTag, message)
    }
}
