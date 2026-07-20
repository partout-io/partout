// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutPortable_C

/// A ``LoggerDestination`` that prints messages to the default platform logger.
public struct SimpleLogDestination: LoggerDestination {
    public init() {
    }

    public func append(_ level: DebugLog.Level, _ msg: String) {
        NSLog(msg)
    }
}
