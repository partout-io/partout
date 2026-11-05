// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import io.partout.models.PartoutErrorCode
import kotlinx.serialization.json.JsonElement

fun interface PartoutCompletionCallback {
    fun onComplete(code: PartoutErrorCode?, json: JsonElement?)
}
