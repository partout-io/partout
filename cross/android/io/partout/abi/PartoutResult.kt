// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class PartoutResult(
    val code: Int,
    val payload: String?
) {
    companion object {
        suspend fun await(
            block: (PartoutCompletionCallback) -> Unit
        ): PartoutResult = withContext(Dispatchers.IO) {
            val future = CompletableDeferred<PartoutResult>()
            block { code, json ->
                future.complete(PartoutResult(code, json))
            }
            val result = future.await()
            if (result.code != 0) {
                throw PartoutException(result.code, result.payload)
            }
            result
        }
    }
}