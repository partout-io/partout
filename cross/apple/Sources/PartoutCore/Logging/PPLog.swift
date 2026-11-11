// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Logs to the context of a ``Profile``.
public func pp_log_id(
    _ profileId: Profile.ID?,
    _ category: LoggerCategory,
    _ level: DebugLog.Level,
    _ message: @autoclosure () -> String
) {
    let ctx: PartoutLoggerContext = profileId.map {
        PartoutLoggerContext($0)
    } ?? .global
    pp_log(ctx, category, level, message())
}

/// Logs to the global context.
public func pp_log_g(
    _ category: LoggerCategory,
    _ level: DebugLog.Level,
    _ message: @autoclosure () -> String
) {
    pp_log(.global, category, level, message())
}

/// Logs to a specific context.
public func pp_log(
    _ ctx: PartoutLoggerContext,
    _ category: LoggerCategory,
    _ level: DebugLog.Level,
    _ message: @autoclosure () -> String
) {
    ctx.logger.log(ctx, category, level, message())
}

extension PartoutLogger {
    func log(
        _ ctx: PartoutLoggerContext,
        _ category: LoggerCategory,
        _ level: DebugLog.Level,
        _ message: @autoclosure () -> String
    ) {
        guard level <= maxLevel else { return }
        let ctxMessage = willPrint(ctx, message())
        if let destination = destination(for: category) {
            destination.append(level, ctxMessage)
        } else if assertsMissingLoggingCategory {
            assertionFailure("LoggingCategory not registered: \(category.rawValue)")
        }
        appendLog(level, message: ctxMessage)
    }
}
