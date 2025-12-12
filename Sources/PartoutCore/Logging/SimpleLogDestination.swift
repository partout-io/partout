// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A ``LoggerDestination`` that prints messages to the default platform logger.
public struct SimpleLogDestination: LoggerDestination {
    public init() {
    }

    public func append(_ level: DebugLog.Level, _ msg: String) {
#if canImport(Darwin)
        NSLog(msg)
#else
#if os(Windows)
        let cLevel = pp_log_level(Int32(level.rawValue))
#else
        let cLevel = pp_log_level(UInt32(level.rawValue))
#endif
        pp_log_simple_append(cLevel, msg)
#endif
    }
}
