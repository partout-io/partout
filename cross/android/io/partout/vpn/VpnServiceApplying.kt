// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import io.partout.extensions.VpnSubnet

internal interface VpnServiceApplying {
    fun apply(logTag: String, builder: VpnService.Builder): Boolean
}

internal fun VpnService.Builder.addDnsServer(subnet: VpnSubnet) {
    addDnsServer(subnet.address)
}

internal fun VpnService.Builder.addRoute(subnet: VpnSubnet) {
    addRoute(subnet.address, subnet.prefixLength)
}

internal fun VpnService.Builder.tryAddAddress(subnet: VpnSubnet): Throwable? {
    return runCatching {
        addAddress(subnet.address, subnet.prefixLength)
    }.exceptionOrNull()
}

internal fun VpnService.Builder.tryAddRoute(subnet: VpnSubnet): Throwable? {
    return runCatching {
        addRoute(subnet)
    }.exceptionOrNull()
}
