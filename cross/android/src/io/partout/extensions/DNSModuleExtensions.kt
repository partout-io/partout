// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.DNSModule
import io.partout.models.DNSModuleProtocolTypehttps
import io.partout.models.DNSModuleProtocolTypetls

internal val DNSModule.unsupportedProtocolName: String?
    get() = when (protocolType) {
        is DNSModuleProtocolTypehttps -> "DoH"
        is DNSModuleProtocolTypetls -> "DoT"
        else -> null
    }
