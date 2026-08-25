// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import io.partout.models.PartoutErrorCode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlin.coroutines.resume

data class PartoutResult(
    val code: PartoutErrorCode?,
    val json: JsonElement?
) {
    companion object {
        suspend fun await(
            block: (PartoutCompletionCallback) -> Unit
        ): PartoutResult = withContext(Dispatchers.IO) {
            val result = suspendCancellableCoroutine { continuation ->
                block { code, json ->
                    continuation.resume(PartoutResult(code, json))
                }
            }
            if (result.code != null) {
                throw PartoutException(null, result.code, result.json)
            }
            result
        }
    }
}
