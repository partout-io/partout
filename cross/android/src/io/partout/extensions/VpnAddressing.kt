// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.Route
import java.net.Inet6Address
import java.net.InetAddress

internal data class VpnSubnet(
    val address: InetAddress,
    val prefixLength: Int
) {
    val cidr: String
        get() = "${address.hostAddress}/$prefixLength"

    companion object {
        fun parse(
            raw: String,
            family: VpnAddressFamily? = null,
            isInterfaceAddress: Boolean = false
        ): VpnSubnet? {
            return runCatching {
                val trimmed = raw.trim()
                require(trimmed.isNotEmpty())

                val parts = trimmed.split("/", limit = 2)
                val address = numericAddress(parts[0].trim()) ?: throw IllegalArgumentException()
                require(family == null || address.family == family)

                val prefixLength = parts.getOrNull(1)?.toInt() ?: address.defaultPrefixLength
                require(address.isValidPrefixLength(prefixLength))
                require(!isInterfaceAddress || address.isValidInterfaceAddress(prefixLength))
                VpnSubnet(address, prefixLength)
            }.getOrNull()
        }

        fun defaultRoutePrefix(family: VpnAddressFamily): VpnSubnet? {
            val address = numericAddress(family.defaultRouteAddress) ?: return null
            return VpnSubnet(address, prefixLength = 0)
        }
    }
}

internal enum class VpnAddressFamily(
    val defaultRouteAddress: String,
    val maxPrefixLength: Int
) {
    IPv4("0.0.0.0", 32),
    IPv6("::", 128)
}

internal fun Route.destinationPrefix(family: VpnAddressFamily): VpnSubnet? {
    val raw = destination?.trim()
    if (raw.isNullOrEmpty()) {
        return VpnSubnet.defaultRoutePrefix(family)
    }
    return VpnSubnet.parse(raw, family = family)
}

private fun numericAddress(address: String): InetAddress? {
    return runCatching {
        require(!address.contains("%"))
        require(address.contains(":") || address.isDottedDecimal())
        InetAddress.getByName(address)
    }.getOrNull()
}

private val InetAddress.family: VpnAddressFamily
    get() = if (this is Inet6Address) VpnAddressFamily.IPv6 else VpnAddressFamily.IPv4

private val InetAddress.defaultPrefixLength: Int
    get() = family.maxPrefixLength

private fun InetAddress.isValidPrefixLength(prefixLength: Int): Boolean {
    return prefixLength in 0..family.maxPrefixLength
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
