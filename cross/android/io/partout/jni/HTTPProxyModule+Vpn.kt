// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.partout.abi.HTTPProxyModule

class HTTPProxyModuleApplying(
    private val module: HTTPProxyModule
): VpnServiceApplying {
    override fun apply(logTag: String, builder: VpnService.Builder): Boolean {
        val endpoint = module.proxy ?: module.secureProxy
        if (endpoint == null) {
            if (module.pacURL != null) {
                Log.i(logTag, "HTTP Proxy: PAC is not supported by VpnService.Builder, skipping")
            } else {
                Log.i(logTag, "HTTP Proxy: no proxy configured")
            }
            return false
        }

        if (module.proxy != null && module.secureProxy != null && module.proxy != module.secureProxy) {
            Log.i(
                logTag,
                "HTTP Proxy: both HTTP and HTTPS proxies are set; Android can use only one proxy, preferring HTTP"
            )
        }

        val (host, port) = endpoint.asHostPort()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.i(logTag, "HTTP Proxy: setHttpProxy is unavailable before API 29, skipping")
            return false
        }
        val proxyInfo = ProxyInfo.buildDirectProxy(host, port, module.bypassDomains.toMutableList())
        Log.i(logTag, "HTTP Proxy: proxy=$host:$port bypass=${module.bypassDomains.joinToString()}")
        builder.setHttpProxy(proxyInfo)

        if (module.pacURL != null) {
            Log.i(logTag, "HTTP Proxy: PAC URL is ignored on Android VPNs: $module.pacURL")
        }
        return true
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
