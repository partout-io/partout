// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.jni

import android.net.VpnService
import io.partout.abi.TaggedModule
import io.partout.abi.TaggedModuleCustom
import io.partout.abi.TaggedModuleDNS
import io.partout.abi.TaggedModuleHTTPProxy
import io.partout.abi.TaggedModuleIP
import io.partout.abi.TaggedModuleOnDemand
import io.partout.abi.TaggedModuleOpenVPN
import io.partout.abi.TaggedModuleWireGuard

internal fun TaggedModule.apply(builder: VpnService.Builder): Boolean {
    return when (this) {
        is TaggedModuleDNS -> value.apply(builder)
        is TaggedModuleHTTPProxy -> {
            value.apply(builder)
            false
        }
        is TaggedModuleIP -> value.apply(builder)
        is TaggedModuleOnDemand -> {
            value.apply(builder)
            false
        }
        is TaggedModuleOpenVPN -> TODO()
        is TaggedModuleWireGuard -> TODO()
        is TaggedModuleCustom -> TODO()
    }
}
