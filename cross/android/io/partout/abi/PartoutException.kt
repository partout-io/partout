// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import io.partout.models.ParseErrorInfo
import io.partout.models.PartoutErrorCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement

class PartoutException(
    val result: Int? = null,
    val code: PartoutErrorCode,
    val payload: JsonElement?
) : RuntimeException("ABI call failed (result=$result, code=$code): $payload") {
    val arguments: List<String>

    init {
        // Best effort (should only succeed with import errors though)
//        if (code == PartoutErrorCode.parsing)
        arguments = payload?.let {
            runCatching {
                val info = Json.decodeFromJsonElement<ParseErrorInfo>(it)
                info.arguments
            }.getOrNull()
        } ?: emptyList()
    }
}
