// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import android.os.Build
import android.util.Log
import io.partout.models.IPModule
import io.partout.models.IPSettings
import io.partout.models.Route
import java.net.Inet6Address
import java.net.InetAddress

class IPModuleApplying(
    private val module: IPModule
): VpnServiceApplying {
    override fun apply(logTag: String, builder: VpnService.Builder): Boolean {
        val addedIPv4Address = module.ipv4?.apply(logTag, builder, isIPv6 = false) == true
        val addedIPv6Address = module.ipv6?.apply(logTag, builder, isIPv6 = true) == true
        module.mtu?.takeIf { it > 0 }?.let {
            Log.i(logTag, "IP: MTU = $it")
            builder.setMtu(it)
        }
        return addedIPv4Address || addedIPv6Address
    }
}

private fun IPSettings.apply(logTag: String, builder: VpnService.Builder, isIPv6: Boolean): Boolean {
    val addedAddress = subnets.fold(false) { addedAddress, rawSubnet ->
        rawSubnet.addAddress(logTag, builder, isIPv6 = isIPv6) || addedAddress
    }
    includedRoutes.forEach { route ->
        route.apply(logTag, builder, isExcluded = false, isIPv6 = isIPv6)
    }
    excludedRoutes.forEach { route ->
        route.apply(logTag, builder, isExcluded = true, isIPv6 = isIPv6)
    }
    return addedAddress
}

private fun String.addAddress(logTag: String, builder: VpnService.Builder, isIPv6: Boolean): Boolean {
    val subnet = subnetFrom(this, isIPv6 = isIPv6, isInterfaceAddress = true)
    if (subnet == null) {
        Log.w(logTag, "IP: Ignoring invalid subnet '$this'")
        return false
    }
    Log.i(logTag, "IP: Address = ${subnet.cidr}")
    return builder.tryAddAddress(subnet.address, subnet.prefixLength)?.let {
        Log.w(logTag, "IP: Unable to add address '$this'", it)
        false
    } ?: true
}

private fun Route.apply(logTag: String, builder: VpnService.Builder, isExcluded: Boolean, isIPv6: Boolean) {
    val routeType = if (isExcluded) "excluded" else "included"
    val prefix = destinationPrefix(isIPv6) ?: run {
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

private fun IpSubnet.includeRoute(logTag: String, builder: VpnService.Builder, route: Route) {
    Log.i(logTag, "IP: Include route $cidr")
    builder.tryAddRoute(address, prefixLength)?.let {
        Log.w(logTag, "IP: Unable to add route '$route'", it)
    }
}

private fun IpSubnet.excludeRoute(logTag: String, builder: VpnService.Builder, route: Route) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
        Log.i(logTag, "IP: Cannot exclude route before API 33: $cidr")
        return
    }
    Log.i(logTag, "IP: Exclude route $cidr")
    builder.tryExcludeRoute(address, prefixLength)?.let {
        Log.w(logTag, "IP: Unable to exclude route '$route'", it)
    }
}

private fun VpnService.Builder.tryAddAddress(address: InetAddress, prefixLength: Int): Throwable? {
    return runCatching {
        addAddress(address, prefixLength)
    }.exceptionOrNull()
}

private fun VpnService.Builder.tryAddRoute(address: InetAddress, prefixLength: Int): Throwable? {
    return runCatching {
        addRoute(address, prefixLength)
    }.exceptionOrNull()
}

private data class IpSubnet(
    val address: InetAddress,
    val prefixLength: Int
) {
    val cidr: String
        get() = "${address.hostAddress}/$prefixLength"
}

private fun Route.destinationPrefix(isIPv6: Boolean): IpSubnet? {
    val raw = destination?.trim()
    if (raw.isNullOrEmpty()) {
        return defaultRoutePrefix(isIPv6)
    }
    return subnetFrom(raw, isIPv6 = isIPv6)
}

private fun defaultRoutePrefix(isIPv6: Boolean): IpSubnet? {
    val address = parseNumericAddress(if (isIPv6) "::" else "0.0.0.0") ?: return null
    return IpSubnet(address, prefixLength = 0)
}

private fun subnetFrom(
    raw: String,
    isIPv6: Boolean,
    isInterfaceAddress: Boolean = false
): IpSubnet? {
    return runCatching {
        val trimmed = raw.trim()
        require(trimmed.isNotEmpty())

        val parts = trimmed.split("/", limit = 2)
        val address = parseNumericAddress(parts[0].trim()) ?: throw IllegalArgumentException()
        require(address.isIPv6 == isIPv6)

        val prefixLength = parts.getOrNull(1)?.toInt() ?: address.defaultPrefixLength()
        require(address.isValidPrefixLength(prefixLength))
        require(!isInterfaceAddress || address.isValidInterfaceAddress(prefixLength))
        IpSubnet(address, prefixLength)
    }.getOrNull()
}

private fun parseNumericAddress(address: String): InetAddress? {
    return runCatching {
        require(!address.contains("%"))
        require(address.contains(":") || address.isDottedDecimal())
        InetAddress.getByName(address)
    }.getOrNull()
}

private val InetAddress.isIPv6: Boolean
    get() = this is Inet6Address

private fun InetAddress.defaultPrefixLength(): Int {
    return maxPrefixLength
}

private val InetAddress.maxPrefixLength: Int
    get() = if (isIPv6) 128 else 32

private fun InetAddress.isValidPrefixLength(prefixLength: Int): Boolean {
    return prefixLength in 0..maxPrefixLength
}

private fun InetAddress.isValidInterfaceAddress(prefixLength: Int): Boolean {
    if (prefixLength == 0) {
        return false
    }
    return !isAnyLocalAddress && !isLoopbackAddress && !isMulticastAddress
}

private fun String.isDottedDecimal(): Boolean {
    val octets = split(".")
    return octets.size == 4 && octets.all { octet ->
        octet.isNotEmpty() && octet.all(Char::isDigit) && octet.toIntOrNull()?.let { it in 0..255 } == true
    }
}
