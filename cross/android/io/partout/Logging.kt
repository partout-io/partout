// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout

import android.util.Log

internal const val REDACTED_VALUE = "<redacted>"

internal fun Any?.sensitiveDescription(logsPrivateData: Boolean): String =
    if (logsPrivateData) toString() else REDACTED_VALUE

internal fun logSensitiveError(
    logTag: String,
    message: String,
    error: Throwable,
    logsPrivateData: Boolean
) {
    if (logsPrivateData) {
        Log.e(logTag, message, error)
    } else {
        Log.e(logTag, "$message (${error.javaClass.name})")
    }
}
