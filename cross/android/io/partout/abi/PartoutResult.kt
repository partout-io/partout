// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

data class PartoutResult(
    val code: Int,
    val json: String?
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
            if (result.code != 0) {
                throw PartoutException(result.code, result.json)
            }
            result
        }
    }
}