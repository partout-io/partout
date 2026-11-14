// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.DNSModule
import io.partout.models.DNSModuleProtocolTypecleartext
import io.partout.models.DNSModuleProtocolTypehttps
import io.partout.models.DNSModuleProtocolTypetls

/** Resolve ordered DNS modules before touching the additive VPN builder APIs. */
internal fun Iterable<DNSModule>.effectiveDNSModule(): DNSModule? {
    var current: DNSModule? = null
    for (module in this) {
        val inherited = current
        if (module.inheritsVPN == true && inherited != null) {
            current = module.copy(
                protocolType = inherited.protocolType,
                servers = inherited.servers,
                domainName = inherited.domainName,
                searchDomains = inherited.searchDomains
            )
            continue
        }
        // NetworkExtension ignores empty cleartext modules, retaining prior DNS.
        if (module.protocolType is DNSModuleProtocolTypecleartext && module.servers.isEmpty()) {
            continue
        }
        current = module
    }
    return current
}

internal val DNSModule.unsupportedProtocolName: String?
    get() = when (protocolType) {
        is DNSModuleProtocolTypehttps -> "DoH"
        is DNSModuleProtocolTypetls -> "DoT"
        else -> null
    }

/** Exclusions take precedence, except on Android versions that cannot apply them. */
internal fun Iterable<DNSModule>.effectiveDNSRouting(supportsExclusions: Boolean): Boolean? {
    var routing: Boolean? = null
    for (module in this) {
        when (module.routesThroughVPN) {
            false -> if (supportsExclusions) return false
            true -> routing = true
            null -> {}
        }
    }
    return routing
}
