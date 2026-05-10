// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.VpnService
import android.util.Log
import io.partout.abi.OnDemandModule

private const val logTag = "Partout"

@Suppress("UNUSED_PARAMETER")
internal fun OnDemandModule.apply(builder: VpnService.Builder) {
    Log.i(logTag, "OnDemand: Android VpnService.Builder does not expose on-demand rules, skipping")
}
