// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

import io.partout.models.PartoutErrorCode
import kotlinx.serialization.json.JsonElement

class PartoutException(
    val result: Int? = null,
    val code: PartoutErrorCode,
    val payload: JsonElement?
) : RuntimeException("ABI call failed (result=$result, code=$code): $payload")