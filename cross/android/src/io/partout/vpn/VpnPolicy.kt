// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.vpn

import android.content.Intent
import android.net.VpnService
import android.os.Build
import io.partout.PartoutVpnServiceRuntime

data class VpnPolicy(
    val alwaysOn: Boolean? = null,
    val lockdown: Boolean? = null
) {
    fun afterLegacyStart(hasIntent: Boolean, appStarted: Boolean, isStop: Boolean): VpnPolicy {
        return if (hasIntent && !appStarted && !isStop) copy(alwaysOn = true) else this
    }

    companion object {
        const val EXTRA_APP_START = "io.partout.extra.APP_START"
        const val EXTRA_ALWAYS_ON = "io.partout.extra.ALWAYS_ON"
        const val EXTRA_LOCKDOWN = "io.partout.extra.LOCKDOWN"

        fun read(service: VpnService, previous: VpnPolicy, intent: Intent? = null): VpnPolicy {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                return VpnPolicy(service.isAlwaysOn, service.isLockdownEnabled)
            }
            // Null intents also occur during ordinary sticky recreation.
            return previous.afterLegacyStart(
                intent != null,
                intent?.getBooleanExtra(EXTRA_APP_START, false) == true,
                intent?.action == PartoutVpnServiceRuntime.ACTION_STOP_VPN
            )
        }
    }
}
