// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@preconcurrency import OSLog
import PartoutCore

/// Represents a ``/PartoutCore/LoggerDestination`` based on `OSLog`.
public struct OSLogDestination: LoggerDestination {
    private static var subsystem: String {
        Partout.identifier
    }

    public let category: LoggerCategory

    private let logger: Logger

    public init(_ category: LoggerCategory) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
    }

    public func append(_ level: DebugLog.Level, _ msg: String) {
        logger.log(level: level.osLogType, "\(msg, privacy: .public)")
    }
}

private extension DebugLog.Level {
    var osLogType: OSLogType {
        switch self {
        case .fault:
            return .fault

        case .error:
            return .error

        case .notice:
            return .default

        case .info:
            return .info

        case .debug:
            return .debug
        }
    }
}
