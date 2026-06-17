// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.partout.models.HTTPProxyModule

class HTTPProxyModuleApplying(
    private val module: HTTPProxyModule
): VpnServiceApplying {
    override fun apply(logTag: String, builder: VpnService.Builder): Boolean {
        val endpoint = module.proxyEndpoint(logTag) ?: return false

        val (host, port) = endpoint.asHostPort()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.i(logTag, "HTTP Proxy: setHttpProxy is unavailable before API 29, skipping")
            return false
        }
        val proxyInfo = ProxyInfo.buildDirectProxy(host, port, module.bypassDomains.toMutableList())
        Log.i(logTag, "HTTP Proxy: proxy=$host:$port bypass=${module.bypassDomains.joinToString()}")
        builder.setHttpProxy(proxyInfo)

        module.logIgnoredPacURL(logTag)
        return true
    }
}

private fun HTTPProxyModule.proxyEndpoint(logTag: String): String? {
    val endpoint = proxy ?: secureProxy
    if (endpoint == null) {
        if (pacURL != null) {
            Log.i(logTag, "HTTP Proxy: PAC is not supported by VpnService.Builder, skipping")
        } else {
            Log.i(logTag, "HTTP Proxy: no proxy configured")
        }
        return null
    }
    if (proxy != null && secureProxy != null && proxy != secureProxy) {
        Log.i(
            logTag,
            "HTTP Proxy: both HTTP and HTTPS proxies are set; Android can use only one proxy, preferring HTTP"
        )
    }
    return endpoint
}

private fun HTTPProxyModule.logIgnoredPacURL(logTag: String) {
    pacURL?.let {
        Log.i(logTag, "HTTP Proxy: PAC URL is ignored on Android VPNs: $it")
    }
}

private data class HostPort(
    val host: String,
    val port: Int
)

private fun String.asHostPort(): HostPort {
    val separator = lastIndexOf(':')
    if (separator <= 0 || separator == lastIndex) {
        return HostPort(this, 0)
    }
    val host = substring(0, separator)
    val port = substring(separator + 1).toIntOrNull() ?: 0
    return HostPort(host, port)
}
