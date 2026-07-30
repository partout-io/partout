// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import io.partout.extensions.VpnSubnet

//region Interface
internal interface VpnServiceApplying {
    fun apply(logTag: String, builder: VpnService.Builder): Boolean
}
//endregion

//region Shared helpers
internal fun VpnService.Builder.addDnsServer(subnet: VpnSubnet) {
    addDnsServer(subnet.address)
}

internal fun VpnService.Builder.addRoute(subnet: VpnSubnet) {
    addRoute(subnet.address, subnet.prefixLength)
}

internal fun VpnService.Builder.addAddress(subnet: VpnSubnet) {
    addAddress(subnet.address, subnet.prefixLength)
}
//endregion
