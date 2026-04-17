// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.partout.abi.IPModule
import io.partout.abi.IPSettings
import io.partout.abi.Route
import java.net.InetAddress

private const val logTag = "Partout"

internal fun IPModule.apply(builder: VpnService.Builder): Boolean {
    var addedAddress = false

    ipv4?.let {
        addedAddress = it.apply(builder, isIPv6 = false) || addedAddress
    }
    ipv6?.let {
        addedAddress = it.apply(builder, isIPv6 = true) || addedAddress
    }

    mtu?.takeIf { it > 0 }?.let {
        Log.i(logTag, "IP: MTU = $it")
        builder.setMtu(it)
    }

    return addedAddress
}

private fun IPSettings.apply(builder: VpnService.Builder, isIPv6: Boolean): Boolean {
    var addedAddress = false

    subnets.forEach { rawSubnet ->
        val subnet = subnetFrom(rawSubnet)
        if (subnet == null) {
            Log.w(logTag, "IP: Ignoring invalid subnet '$rawSubnet'")
            return@forEach
        }
        Log.i(logTag, "IP: Address = ${subnet.address}/${subnet.prefixLength}")
        builder.addAddress(subnet.address, subnet.prefixLength)
        addedAddress = true
    }

    includedRoutes.forEach { route ->
        route.apply(builder, isExcluded = false, isIPv6 = isIPv6)
    }

    excludedRoutes.forEach { route ->
        route.apply(builder, isExcluded = true, isIPv6 = isIPv6)
    }

    return addedAddress
}

private fun Route.apply(builder: VpnService.Builder, isExcluded: Boolean, isIPv6: Boolean) {
    val prefix = destinationPrefix(isIPv6) ?: run {
        Log.w(logTag, "IP: Ignoring invalid ${if (isExcluded) "excluded" else "included"} route '$this'")
        return
    }

    if (gateway != null) {
        Log.i(logTag, "IP: Route gateway is ignored on Android VPNs: ${gateway}")
    }

        when {
            isExcluded && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                Log.i(logTag, "IP: Exclude route ${prefix.address}/${prefix.prefixLength}")
                prefix.toIpPrefix()?.let {
                    builder.excludeRoute(it)
                } ?: Log.w(logTag, "IP: Unable to build route exclusion for '$this'")
            }
            isExcluded -> {
                Log.i(logTag, "IP: Cannot exclude route before API 33: ${prefix.address}/${prefix.prefixLength}")
            }
            else -> {
            Log.i(logTag, "IP: Include route ${prefix.address}/${prefix.prefixLength}")
            builder.addRoute(prefix.address, prefix.prefixLength)
        }
    }
}

private data class IpNumericSubnet(
    val address: String,
    val prefixLength: Int
)

private data class IpPrefixRoute(
    val address: String,
    val prefixLength: Int
)

private fun Route.destinationPrefix(isIPv6: Boolean): IpPrefixRoute? {
    val raw = destination?.trim()
    if (raw.isNullOrEmpty()) {
        return IpPrefixRoute(
            address = if (isIPv6) "::" else "0.0.0.0",
            prefixLength = 0
        )
    }
    return subnetFrom(raw)?.let { IpPrefixRoute(it.address, it.prefixLength) }
}

private fun subnetFrom(raw: String): IpNumericSubnet? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) {
        return null
    }

    val parts = trimmed.split("/", limit = 2)
    val address = parts[0].trim()
    val prefixLength = parts.getOrNull(1)?.toIntOrNull() ?: defaultPrefixLength(address)
    if (prefixLength == null) {
        return null
    }
    if (!isNumericAddress(address)) {
        return null
    }
    return IpNumericSubnet(address, prefixLength)
}

private fun defaultPrefixLength(address: String): Int? {
    return when {
        address.contains(":") -> 128
        address.contains(".") -> 32
        else -> null
    }
}

private fun isNumericAddress(address: String): Boolean {
    return address.contains(":") || address.matches(Regex("""\d{1,3}(\.\d{1,3}){3}"""))
}

private fun IpPrefixRoute.toIpPrefix(): IpPrefix? {
    return runCatching {
        IpPrefix(InetAddress.getByName(address), prefixLength)
    }.getOrNull()
}
