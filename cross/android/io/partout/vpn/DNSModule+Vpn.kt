// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import android.util.Log
import io.partout.extensions.VpnSubnet
import io.partout.extensions.unsupportedProtocolName
import io.partout.models.DNSModule

internal class DNSModuleApplying(
    private val module: DNSModule
): VpnServiceApplying {
    override fun apply(logTag: String, builder: VpnService.Builder, logsPrivateData: Boolean): Boolean {
        if (!module.applyServers(logTag, builder, logsPrivateData)) {
            return false
        }
        module.addSearchDomains(logTag, builder, logsPrivateData)
        return true
    }
}

private fun DNSModule.applyServers(
    logTag: String,
    builder: VpnService.Builder,
    logsPrivateData: Boolean
): Boolean {
    val protocolName = unsupportedProtocolName
    if (protocolName != null) {
        Log.i(
            logTag,
            "DNS: $protocolName is not supported by VpnService.Builder, using numeric servers only"
        )
        return addServers(
            logTag,
            builder,
            routed = routesThroughVPN == true,
            logsPrivateData = logsPrivateData
        )
    }
    if (servers.isEmpty()) {
        Log.i(logTag, "DNS: cleartext DNS without servers is ignored")
        return false
    }
    return addServers(
        logTag,
        builder,
        routed = routesThroughVPN == true,
        logsPrivateData = logsPrivateData
    )
}

private fun DNSModule.addSearchDomains(
    logTag: String,
    builder: VpnService.Builder,
    logsPrivateData: Boolean
) {
    domainName?.takeIf { it.isNotBlank() }?.let {
        Log.i(logTag, "DNS: Search domain (domainName): ${it.sensitiveDescription(logsPrivateData)}")
        builder.addSearchDomain(it)
    }
    searchDomains.orEmpty().forEach { domain ->
        if (domain.isNotBlank()) {
            Log.i(logTag, "DNS: Search domain: ${domain.sensitiveDescription(logsPrivateData)}")
            builder.addSearchDomain(domain)
        }
    }
}

internal fun DNSModule.addServers(
    logTag: String,
    builder: VpnService.Builder,
    routed: Boolean,
    logsPrivateData: Boolean
): Boolean {
    var addedServers = false
    servers.forEach { server ->
        val route = VpnSubnet.parse(server)
        if (route == null) {
            Log.w(logTag, "DNS: Ignoring invalid server '${server.sensitiveDescription(logsPrivateData)}'")
            return@forEach
        }
        Log.i(logTag, "DNS: Server: ${route.cidr.sensitiveDescription(logsPrivateData)}")
        builder.addDnsServer(route)
        addedServers = true
        when {
            routed -> {
                Log.i(logTag, "DNS: Route server through VPN: ${route.cidr.sensitiveDescription(logsPrivateData)}")
                builder.addRoute(route)
            }
        }
    }
    return addedServers
}

internal fun List<String>.addDNSServers(
    logTag: String,
    builder: VpnService.Builder,
    logsPrivateData: Boolean
) {
    forEach { server ->
        val route = VpnSubnet.parse(server)
        if (route == null) {
            Log.w(logTag, "DNS: Ignoring invalid fallback server '${server.sensitiveDescription(logsPrivateData)}'")
            return@forEach
        }
        Log.i(logTag, "DNS: Fallback server: ${route.cidr.sensitiveDescription(logsPrivateData)}")
        builder.addDnsServer(route)
    }
}
