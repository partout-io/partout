//
//  OSLogDestination.swift
//  Partout
//
//  Created by Davide De Rosa on 5/4/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

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
