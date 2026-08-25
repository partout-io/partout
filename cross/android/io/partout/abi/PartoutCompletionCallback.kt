// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import kotlinx.serialization.json.JsonElement

fun interface PartoutCompletionCallback {
    fun onComplete(code: Int, json: JsonElement?)
}
