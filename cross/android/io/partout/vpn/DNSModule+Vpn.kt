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
        val route = VpnSubnet.parse(server)
        if (route == null) {
            Log.w(logTag, "DNS: Ignoring invalid server '$server'")
            return@forEach
        }
        Log.i(logTag, "DNS: Server: ${route.cidr}")
        builder.addDnsServer(route)
        when {
            routed -> {
                Log.i(logTag, "DNS: Route server through VPN: ${route.cidr}")
                builder.addRoute(route)
            }
        }
    }
}
