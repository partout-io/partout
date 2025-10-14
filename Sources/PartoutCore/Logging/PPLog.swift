// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

public func pp_log_id(
    _ profileId: Profile.ID?,
    _ category: LoggerCategory,
    _ level: DebugLog.Level,
    _ message: String
) {
    let ctx: PartoutLoggerContext = profileId.map {
        PartoutLoggerContext($0)
    } ?? .global
    pp_log(ctx, category, level, message)
}

public func pp_log_g(
    _ category: LoggerCategory,
    _ level: DebugLog.Level,
    _ message: String
) {
    pp_log(.global, category, level, message)
}

public func pp_log(
    _ ctx: PartoutLoggerContext,
    _ category: LoggerCategory,
    _ level: DebugLog.Level,
    _ message: String
) {
    let logger = ctx.logger
    let ctxMessage = logger.willPrint(ctx, message)
    if let destination = logger.destination(for: category) {
        destination.append(level, ctxMessage)
    } else if logger.assertsMissingLoggingCategory {
        assertionFailure("LoggingCategory not registered: \(category.rawValue)")
    }
    logger.appendLog(level, message: ctxMessage)
}
