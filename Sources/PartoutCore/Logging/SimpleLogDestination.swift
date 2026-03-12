// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A ``LoggerDestination`` that prints messages to the default platform logger.
public struct SimpleLogDestination: LoggerDestination {
    private let tag: String?

    public init(tag: String?) {
        self.tag = tag
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
        if let tag {
            tag.withCString {
                pp_log_simple_append($0, cLevel, msg)
            }
        } else {
            pp_log_simple_append(nil, cLevel, msg)
        }
#endif
    }
}
