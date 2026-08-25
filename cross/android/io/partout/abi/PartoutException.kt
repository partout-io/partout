// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import io.partout.models.ABIErrorPayload
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement

class PartoutException(
    val code: Int,
    json: JsonElement?
) : RuntimeException("ABI call failed (code=$code): $json") {
    val payload: ABIErrorPayload?

    init {
        payload = json?.let {
            runCatching {
                Json.decodeFromJsonElement<ABIErrorPayload>(json)
            }.getOrNull()
        }
    }
}
