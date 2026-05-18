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
        var applied = when (module.protocolType) {
            is DNSModuleProtocolTypehttps, is DNSModuleProtocolTypetls -> true
            else -> module.servers.isNotEmpty()
        }

        when (module.protocolType) {
            is DNSModuleProtocolTypehttps -> {
                Log.i(
                    logTag,
                    "DNS: DoH is not supported by VpnService.Builder, using numeric servers only"
                )
                module.addServers(logTag, builder, routed = module.routesThroughVPN == true)
            }

            is DNSModuleProtocolTypetls -> {
                Log.i(
                    logTag,
                    "DNS: DoT is not supported by VpnService.Builder, using numeric servers only"
                )
                module.addServers(logTag, builder, routed = module.routesThroughVPN == true)
            }

            else -> {
                if (module.servers.isNotEmpty()) {
                    module.addServers(logTag, builder, routed = module.routesThroughVPN == true)
                } else {
                    Log.i(logTag, "DNS: cleartext DNS without servers is ignored")
                }
            }
        }

        if (!applied) {
            return false
        }

        module.domainName?.takeIf { it.isNotBlank() }?.let {
            Log.i(logTag, "DNS: Search domain (domainName): $it")
            builder.addSearchDomain(it)
        }

        module.searchDomains.orEmpty().forEach { domain ->
            if (domain.isNotBlank()) {
                Log.i(logTag, "DNS: Search domain: $domain")
                builder.addSearchDomain(domain)
            }
        }

        return applied
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
