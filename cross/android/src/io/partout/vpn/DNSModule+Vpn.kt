// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import android.util.Log
import java.net.Inet6Address
import io.partout.extensions.VpnSubnet
import io.partout.extensions.unsupportedProtocolName
import io.partout.models.IPModule
import io.partout.models.DNSModule
import io.partout.sensitiveDescription

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
    builder: VpnService.Builder
) {
    forEach { server ->
        val route = VpnSubnet.parse(server)
        if (route == null) {
            Log.w(logTag, "DNS: Ignoring invalid fallback server '$server'")
            return@forEach
        }
        Log.i(logTag, "DNS: Fallback server: ${route.cidr}")
        builder.addDnsServer(route)
    }
}

// Apply routing policies to the committed servers, including fallback DNS.
internal fun applyDNSServerRoutes(
    logTag: String,
    builder: VpnService.Builder,
    servers: List<String>,
    ip: IPModule?,
    routed: Boolean
) {
    servers.forEach { server ->
        val subnet = VpnSubnet.parse(server) ?: return@forEach
        val isIPv6 = subnet.address is Inet6Address
        if (isIPv6 && ip?.ipv6 == null || !isIPv6 && ip?.ipv4 == null) return@forEach
        val hostRoute = subnet.copy(prefixLength = if (isIPv6) 128 else 32)
        val failure = if (routed) {
            runCatching { builder.addRoute(hostRoute) }.exceptionOrNull()
        } else {
            builder.tryExcludeRoute(hostRoute)
        }
        if (failure != null) {
            Log.i(logTag, "DNS: Unable to apply server route: $failure")
        }
    }
}
