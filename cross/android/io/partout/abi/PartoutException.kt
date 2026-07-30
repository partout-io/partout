// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import io.partout.models.ABIErrorPayload
import kotlinx.serialization.json.Json

class PartoutException(
    val code: Int,
    json: String?
) : RuntimeException("ABI call failed (code=$code): $json") {
    val payload: ABIErrorPayload?

    init {
        payload = json?.let {
            runCatching {
                Json.decodeFromString<ABIErrorPayload>(json)
            }.getOrNull()
        }
    }
}
