// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.partout.abi.DNSModule
import io.partout.abi.DNSModuleProtocolTypehttps
import io.partout.abi.DNSModuleProtocolTypetls
import io.partout.abi.Route
import java.net.InetAddress

private const val logTag = "Partout"

internal fun DNSModule.apply(builder: VpnService.Builder): Boolean {
    var applied = when (protocolType) {
        is DNSModuleProtocolTypehttps, is DNSModuleProtocolTypetls -> true
        else -> servers.isNotEmpty()
    }

    when (protocolType) {
        is DNSModuleProtocolTypehttps -> {
            Log.i(logTag, "DNS: DoH is not supported by VpnService.Builder, using numeric servers only")
            addServers(builder, routed = routesThroughVPN == true)
        }
        is DNSModuleProtocolTypetls -> {
            Log.i(logTag, "DNS: DoT is not supported by VpnService.Builder, using numeric servers only")
            addServers(builder, routed = routesThroughVPN == true)
        }
        else -> {
            if (servers.isNotEmpty()) {
                addServers(builder, routed = routesThroughVPN == true)
            } else {
                Log.i(logTag, "DNS: cleartext DNS without servers is ignored")
            }
        }
    }

    if (!applied) {
        return false
    }

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

    return applied
}

fun DNSModule.addServers(
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
//            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
//                Log.i(logTag, "DNS: Keep server outside VPN: ${route.address}/${route.prefixLength}")
//                route.toIpPrefix()?.let {
//                    builder.excludeRoute(it)
//                } ?: Log.w(logTag, "DNS: Unable to build route exclusion for '$server'")
//            }
//            else -> {
//                Log.i(logTag, "DNS: Cannot exclude DNS server route before API 33: ${route.address}/${route.prefixLength}")
//            }
        }
    }
}

private data class DnsNumericSubnet(
    val address: String,
    val prefixLength: Int
)

private fun subnetFrom(raw: String): DnsNumericSubnet? {
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
    return DnsNumericSubnet(address, prefixLength)
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

private fun DnsNumericSubnet.toIpPrefix(): IpPrefix? {
    return runCatching {
        IpPrefix(InetAddress.getByName(address), prefixLength)
    }.getOrNull()
}

private fun Route.toIpPrefix(): IpPrefix? {
    val destination = destination ?: return null
    val subnet = subnetFrom(destination) ?: return null
    return subnet.toIpPrefix()
}
