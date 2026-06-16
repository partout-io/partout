// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.abi

class PartoutException(
    val code: Int,
    payload: String?
) : RuntimeException("ABI call failed (code=$code): $payload")
