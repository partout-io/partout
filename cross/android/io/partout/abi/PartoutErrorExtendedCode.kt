// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import io.partout.models.PartoutErrorCode
import io.partout.models.PartoutErrorExtendedCode

fun String.extendedErrorCode(): PartoutErrorExtendedCode? {
    val components = split(".", limit = 2)
    val code = PartoutErrorCode.decode(components[0]) ?: return null
    val subCode = components.getOrNull(1)
    if (subCode != null && subCode.isEmpty()) return null
    return PartoutErrorExtendedCode(code, subCode)
}

val PartoutErrorExtendedCode.rawValue: String
    get() = subCode?.let { "${code.value}.$it" } ?: code.value
