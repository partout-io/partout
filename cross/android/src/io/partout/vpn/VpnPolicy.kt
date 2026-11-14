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
    /**
     * API 24-28 cannot query Always-on or lockdown through VpnService. A non-null
     * start intent without EXTRA_APP_START is therefore treated as evidence of an
     * Android Always-on start. Every app-originated start, including boot/update
     * restoration, must carry that flag to avoid a false positive.
     *
     * An app start does not prove Always-on is disabled, and a null intent may be
     * an ordinary START_STICKY restart. Neither replaces the current inference;
     * stop commands provide no evidence either. Lockdown cannot be inferred from
     * start origin and remains unknown until explicitly cleared on revocation.
     *
     * This inference belongs only to the current runtime instance. Do not persist
     * it: the user could disable Always-on while the process is dead, leaving no
     * onRevoke callback to invalidate a saved value. A recreated runtime starts
     * with unknown policy, so a null sticky restart can temporarily leave an
     * actual Always-on connection unrecognized. This is preferable to enforcing
     * an obsolete persisted policy indefinitely. Revocation clears the live
     * state; otherwise it remains a best-effort inference, not a settings query.
     * API 29+ bypasses this inference and reads both flags directly from Android.
     */
    fun afterLegacyStart(hasIntent: Boolean, appStarted: Boolean, isStop: Boolean): VpnPolicy {
        return if (hasIntent && !appStarted && !isStop) copy(alwaysOn = true) else this
    }

    companion object {
        const val EXTRA_APP_START = "io.partout.extra.APP_START"
        const val EXTRA_ALWAYS_ON = "io.partout.extra.ALWAYS_ON"
        const val EXTRA_LOCKDOWN = "io.partout.extra.LOCKDOWN"

        fun read(service: VpnService, previous: VpnPolicy, intent: Intent? = null): VpnPolicy {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                return previous.afterLegacyStart(
                    intent != null,
                    intent?.getBooleanExtra(EXTRA_APP_START, false) == true,
                    intent?.action == PartoutVpnServiceRuntime.ACTION_STOP_VPN
                )
            }
            return VpnPolicy(service.isAlwaysOn, service.isLockdownEnabled)
        }
    }
}
