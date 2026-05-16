// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.VpnService

interface VpnServiceApplying {
    fun apply(logTag: String, builder: VpnService.Builder): Boolean
}