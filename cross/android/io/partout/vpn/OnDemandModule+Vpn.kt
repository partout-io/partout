// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.net.VpnService
import android.util.Log
import io.partout.models.OnDemandModule

class OnDemandModuleApplying(
    @Suppress("UNUSED_PARAMETER")
    module: OnDemandModule
): VpnServiceApplying {
    @Suppress("UNUSED_PARAMETER")
    override fun apply(logTag: String, builder: VpnService.Builder): Boolean {
        Log.i(
            logTag,
            "OnDemand: Android VpnService.Builder does not expose on-demand rules, skipping"
        )
        return false
    }
}
