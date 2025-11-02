// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A ``LoggerDestination`` that prints messages via `NSLog`.
public struct NSLogDestination: LoggerDestination {
    public init() {
    }

    public func append(_ level: DebugLog.Level, _ msg: String) {
        NSLog(msg)
    }
}
