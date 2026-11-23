// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.HTTPProxyModule

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
