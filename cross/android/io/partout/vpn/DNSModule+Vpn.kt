// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import android.util.Log
import io.partout.models.DNSModule
import io.partout.models.DNSModuleProtocolTypehttps
import io.partout.models.DNSModuleProtocolTypetls

class DNSModuleApplying(
    private val module: DNSModule
): VpnServiceApplying {
    override fun apply(logTag: String, builder: VpnService.Builder): Boolean {
        if (!module.applyServers(logTag, builder)) {
            return false
        }
        module.addSearchDomains(logTag, builder)
        return true
    }
}

private fun DNSModule.applyServers(
    logTag: String,
    builder: VpnService.Builder
): Boolean {
    val unsupportedProtocolName = unsupportedProtocolName()
    if (unsupportedProtocolName != null) {
        Log.i(
            logTag,
            "DNS: $unsupportedProtocolName is not supported by VpnService.Builder, using numeric servers only"
        )
        addServers(logTag, builder, routed = routesThroughVPN == true)
        return true
    }
    if (servers.isEmpty()) {
        Log.i(logTag, "DNS: cleartext DNS without servers is ignored")
        return false
    }
    addServers(logTag, builder, routed = routesThroughVPN == true)
    return true
}

private fun DNSModule.unsupportedProtocolName(): String? {
    return when (protocolType) {
        is DNSModuleProtocolTypehttps -> "DoH"
        is DNSModuleProtocolTypetls -> "DoT"
        else -> null
    }
}

private fun DNSModule.addSearchDomains(
    logTag: String,
    builder: VpnService.Builder
) {
    domainName?.takeIf { it.isNotBlank() }?.let {
        Log.i(logTag, "DNS: Search domain (domainName): $it")
        builder.addSearchDomain(it)
    }
    searchDomains.orEmpty().forEach { domain ->
        if (domain.isNotBlank()) {
            Log.i(logTag, "DNS: Search domain: $domain")
            builder.addSearchDomain(domain)
        }
    }
}

fun DNSModule.addServers(
    logTag: String,
    builder: VpnService.Builder,
    routed: Boolean
) {
    servers.forEach { server ->
        val route = subnetFrom(server)
        if (route == null) {
            Log.w(logTag, "DNS: Ignoring invalid server '$server'")
            return@forEach
        }
        Log.i(logTag, "DNS: Server: ${route.address}/${route.prefixLength}")
        builder.addDnsServer(route.address)
        when {
            routed -> {
                Log.i(logTag, "DNS: Route server through VPN: ${route.address}/${route.prefixLength}")
                builder.addRoute(route.address, route.prefixLength)
            }
        }
    }
}

private data class DnsNumericSubnet(
    val address: String,
    val prefixLength: Int
)

private fun subnetFrom(raw: String): DnsNumericSubnet? {
    return runCatching {
        val trimmed = raw.trim()
        require(trimmed.isNotEmpty())

        val parts = trimmed.split("/", limit = 2)
        val address = parts[0].trim()
        require(isNumericAddress(address))

        val prefixLength = parts.getOrNull(1)?.toInt() ?: defaultPrefixLength(address)
        DnsNumericSubnet(address, prefixLength)
    }.getOrNull()
}

private fun defaultPrefixLength(address: String): Int {
    return when {
        address.contains(":") -> 128
        address.contains(".") -> 32
        else -> throw IllegalArgumentException("Unsupported DNS server address")
    }
}

private fun isNumericAddress(address: String): Boolean {
    return address.contains(":") || address.matches(Regex("""\d{1,3}(\.\d{1,3}){3}"""))
}
