// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.VpnService
import android.os.Build
import android.util.Log
import io.partout.abi.IPModule
import io.partout.abi.IPSettings
import io.partout.abi.Route
import java.net.Inet6Address
import java.net.InetAddress

class IPModuleApplying(
    private val module: IPModule
): VpnServiceApplying {
    override fun apply(logTag: String, builder: VpnService.Builder): Boolean {
        var addedAddress = false
        module.ipv4?.let {
            addedAddress = it.apply(logTag, builder, isIPv6 = false) || addedAddress
        }
        module.ipv6?.let {
            addedAddress = it.apply(logTag, builder, isIPv6 = true) || addedAddress
        }
        module.mtu?.takeIf { it > 0 }?.let {
            Log.i(logTag, "IP: MTU = $it")
            builder.setMtu(it)
        }
        return addedAddress
    }
}

private fun IPSettings.apply(logTag: String, builder: VpnService.Builder, isIPv6: Boolean): Boolean {
    var addedAddress = false
    subnets.forEach { rawSubnet ->
        val subnet = subnetFrom(rawSubnet, isIPv6 = isIPv6, isInterfaceAddress = true)
        if (subnet == null) {
            Log.w(logTag, "IP: Ignoring invalid subnet '$rawSubnet'")
            return@forEach
        }
        Log.i(logTag, "IP: Address = ${subnet.address.hostAddress}/${subnet.prefixLength}")
        runCatching {
            builder.addAddress(subnet.address, subnet.prefixLength)
        }.onSuccess {
            addedAddress = true
        }.onFailure {
            Log.w(logTag, "IP: Unable to add address '$rawSubnet'", it)
        }
    }
    includedRoutes.forEach { route ->
        route.apply(logTag, builder, isExcluded = false, isIPv6 = isIPv6)
    }
    excludedRoutes.forEach { route ->
        route.apply(logTag, builder, isExcluded = true, isIPv6 = isIPv6)
    }
    return addedAddress
}

private fun Route.apply(logTag: String, builder: VpnService.Builder, isExcluded: Boolean, isIPv6: Boolean) {
    val prefix = destinationPrefix(isIPv6) ?: run {
        Log.w(logTag, "IP: Ignoring invalid ${if (isExcluded) "excluded" else "included"} route '$this'")
        return
    }

    if (gateway != null) {
        Log.i(logTag, "IP: Route gateway is ignored on Android VPNs: ${gateway}")
    }

    when {
        isExcluded && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
            Log.i(logTag, "IP: Exclude route ${prefix.address.hostAddress}/${prefix.prefixLength}")
            builder.tryExcludeRoute(prefix.address, prefix.prefixLength)?.let {
                Log.w(logTag, "IP: Unable to exclude route '$this'", it)
            }
        }
        isExcluded -> {
            Log.i(logTag, "IP: Cannot exclude route before API 33: ${prefix.address.hostAddress}/${prefix.prefixLength}")
        }
        else -> {
            Log.i(logTag, "IP: Include route ${prefix.address.hostAddress}/${prefix.prefixLength}")
            runCatching {
                builder.addRoute(prefix.address, prefix.prefixLength)
            }.onFailure {
                Log.w(logTag, "IP: Unable to add route '$this'", it)
            }
        }
    }
}

private data class IpNumericSubnet(
    val address: InetAddress,
    val prefixLength: Int
)

private data class RoutePrefix(
    val address: InetAddress,
    val prefixLength: Int
)

private fun Route.destinationPrefix(isIPv6: Boolean): RoutePrefix? {
    val raw = destination?.trim()
    if (raw.isNullOrEmpty()) {
        val address = parseNumericAddress(if (isIPv6) "::" else "0.0.0.0") ?: return null
        return RoutePrefix(
            address = address,
            prefixLength = 0
        )
    }
    return subnetFrom(raw, isIPv6 = isIPv6)?.let { RoutePrefix(it.address, it.prefixLength) }
}

private fun subnetFrom(
    raw: String,
    isIPv6: Boolean,
    isInterfaceAddress: Boolean = false
): IpNumericSubnet? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) {
        return null
    }

    val parts = trimmed.split("/", limit = 2)
    val address = parseNumericAddress(parts[0].trim()) ?: return null
    if (isIPv6 != (address is Inet6Address)) {
        return null
    }
    val prefixLength = parts.getOrNull(1)?.toIntOrNull() ?: defaultPrefixLength(address)
    if (!isValidPrefixLength(address, prefixLength)) {
        return null
    }
    if (isInterfaceAddress && !address.isValidInterfaceAddress(prefixLength)) {
        return null
    }
    return IpNumericSubnet(address, prefixLength)
}

private fun parseNumericAddress(address: String): InetAddress? {
    if (address.contains("%")) {
        return null
    }
    if (!address.contains(":") && !address.isDottedDecimal()) {
        return null
    }
    return runCatching {
        InetAddress.getByName(address)
    }.getOrNull()
}

private fun defaultPrefixLength(address: InetAddress): Int {
    return if (address is Inet6Address) 128 else 32
}

private fun isValidPrefixLength(address: InetAddress, prefixLength: Int): Boolean {
    val maxPrefixLength = if (address is Inet6Address) 128 else 32
    return prefixLength >= 0 && prefixLength <= maxPrefixLength
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
        octet.isNotEmpty() && octet.all(Char::isDigit) && octet.toIntOrNull() in 0..255
    }
}
