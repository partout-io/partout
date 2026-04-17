// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.partout.abi.HTTPProxyModule

private const val logTag = "Partout"

internal fun HTTPProxyModule.apply(builder: VpnService.Builder) {
    val endpoint = proxy ?: secureProxy
    if (endpoint == null) {
        if (pacURL != null) {
            Log.i(logTag, "HTTP Proxy: PAC is not supported by VpnService.Builder, skipping")
        } else {
            Log.i(logTag, "HTTP Proxy: no proxy configured")
        }
        return
    }

    if (proxy != null && secureProxy != null && proxy != secureProxy) {
        Log.i(logTag, "HTTP Proxy: both HTTP and HTTPS proxies are set; Android can use only one proxy, preferring HTTP")
    }

    val (host, port) = endpoint.asHostPort()
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        Log.i(logTag, "HTTP Proxy: setHttpProxy is unavailable before API 29, skipping")
        return
    }
    val proxyInfo = ProxyInfo.buildDirectProxy(host, port, bypassDomains.toMutableList())
    Log.i(logTag, "HTTP Proxy: proxy=$host:$port bypass=${bypassDomains.joinToString()}")
    builder.setHttpProxy(proxyInfo)

    if (pacURL != null) {
        Log.i(logTag, "HTTP Proxy: PAC URL is ignored on Android VPNs: $pacURL")
    }
}

private fun String.asHostPort(): Pair<String, Int> {
    val idx = lastIndexOf(':')
    if (idx <= 0 || idx == lastIndex) {
        return this to 0
    }
    val host = substring(0, idx)
    val port = substring(idx + 1).toIntOrNull() ?: 0
    return host to port
}
