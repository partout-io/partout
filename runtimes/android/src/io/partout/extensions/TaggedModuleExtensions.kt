// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.ModuleType
import io.partout.models.TaggedModule
import io.partout.models.TaggedModuleDNS
import io.partout.models.TaggedModuleHTTPProxy
import io.partout.models.TaggedModuleIP
import io.partout.models.TaggedModuleOnDemand
import io.partout.models.TaggedModuleOpenVPN
import io.partout.models.TaggedModuleWireGuard

val TaggedModule.moduleType: ModuleType?
    get() = when (this) {
        is TaggedModuleDNS -> ModuleType.DNS
        is TaggedModuleHTTPProxy -> ModuleType.HTTPProxy
        is TaggedModuleIP -> ModuleType.IP
        is TaggedModuleOnDemand -> ModuleType.OnDemand
        is TaggedModuleOpenVPN -> ModuleType.OpenVPN
        is TaggedModuleWireGuard -> ModuleType.WireGuard
        else -> null
    }

val TaggedModule.moduleId: String?
    get() = when (this) {
        is TaggedModuleDNS -> value.id
        is TaggedModuleHTTPProxy -> value.id
        is TaggedModuleIP -> value.id
        is TaggedModuleOnDemand -> value.id
        is TaggedModuleOpenVPN -> value.id
        is TaggedModuleWireGuard -> value.id
        else -> null
    }

val TaggedModule.isInteractive: Boolean
    get() = when (this) {
        is TaggedModuleOpenVPN -> value.isInteractive
        else -> false
    }
