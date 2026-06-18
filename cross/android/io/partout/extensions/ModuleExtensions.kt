// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.DNSModule
import io.partout.models.DNSModuleProtocolTypehttps
import io.partout.models.DNSModuleProtocolTypetls
import io.partout.models.HTTPProxyModule
import io.partout.models.Route
import java.net.Inet6Address
import java.net.InetAddress

//region DNS
internal val DNSModule.unsupportedProtocolName: String?
    get() = when (protocolType) {
        is DNSModuleProtocolTypehttps -> "DoH"
        is DNSModuleProtocolTypetls -> "DoT"
        else -> null
    }
//endregion

//region HTTPProxy
internal val HTTPProxyModule.proxyEndpoint: String?
    get() = proxy ?: secureProxy

internal val HTTPProxyModule.hasProxyConflict: Boolean
    get() = proxy != null && secureProxy != null && proxy != secureProxy

internal data class HostPort(
    val host: String,
    val port: Int
)

internal fun String.asHostPort(): HostPort {
    val separator = lastIndexOf(':')
    if (separator <= 0 || separator == lastIndex) {
        return HostPort(this, 0)
    }
    val host = substring(0, separator)
    val port = substring(separator + 1).toIntOrNull() ?: 0
    return HostPort(host, port)
}
//endregion

//region IP
internal enum class VpnAddressFamily(
    val defaultRouteAddress: String,
    val maxPrefixLength: Int
) {
    IPv4("0.0.0.0", 32),
    IPv6("::", 128)
}

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
//endregion
