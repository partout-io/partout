// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import android.os.Build
import io.partout.extensions.VpnSubnet
import java.lang.reflect.InvocationTargetException
import java.net.InetAddress

private const val IP_PREFIX_CLASS_NAME = "android.net.IpPrefix"

internal fun VpnService.Builder.tryExcludeRoute(subnet: VpnSubnet): Throwable? {
    return tryExcludeRoute(subnet.address, subnet.prefixLength)
}

internal fun VpnService.Builder.tryExcludeRoute(
    address: InetAddress,
    prefixLength: Int
): Throwable? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
        return UnsupportedOperationException("VpnService.Builder.excludeRoute requires API 33")
    }

    return runCatching {
        val ipPrefixClass = Class.forName(IP_PREFIX_CLASS_NAME)
        val ipPrefix = ipPrefixClass
            .getConstructor(InetAddress::class.java, Int::class.javaPrimitiveType!!)
            .newInstance(address, prefixLength)
        VpnService.Builder::class.java
            .getMethod("excludeRoute", ipPrefixClass)
            .invoke(this, ipPrefix)
    }.exceptionOrNull()?.unwrapped()
}

private fun Throwable.unwrapped(): Throwable {
    return if (this is InvocationTargetException) {
        targetException ?: this
    } else {
        this
    }
}
