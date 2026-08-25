// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import io.partout.models.ABIErrorPayload
import io.partout.models.ParseErrorInfo
import io.partout.models.PartoutErrorCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement

class PartoutException(
    val code: Int,
    json: JsonElement?
) : RuntimeException("ABI call failed (code=$code): $json") {
    val errorCode: PartoutErrorCode
    val userInfo: JsonElement?
    val arguments: List<String>

    init {
        val payload = json?.let {
            runCatching {
                Json.decodeFromJsonElement<ABIErrorPayload>(json)
            }.getOrNull()
        }
        errorCode = payload?.code ?: PartoutErrorCode.unhandled
        userInfo = payload?.userInfo

        // Best effort (should only succeed with import errors though)
        arguments = userInfo?.let {
            runCatching {
                val info = Json.decodeFromJsonElement<ParseErrorInfo>(payload.userInfo)
                info.arguments
            }.getOrNull()
        } ?: emptyList()
    }
}
