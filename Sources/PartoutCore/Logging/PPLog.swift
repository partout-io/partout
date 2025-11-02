// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Logs to the context of a ``Profile``.
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

/// Logs to the global context.
public func pp_log_g(
    _ category: LoggerCategory,
    _ level: DebugLog.Level,
    _ message: String
) {
    pp_log(.global, category, level, message)
}

/// Logs to a specific context.
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

/// Logs to the global context from C code.
@_cdecl("pp_clog")
public func pp_clog(
    _ cCategory: UnsafePointer<CChar>,
    _ cLevel: Int,
    _ cMessage: UnsafePointer<CChar>
) {
    let category = LoggerCategory(rawValue: String(cString: cCategory))
    let level = DebugLog.Level(rawValue: cLevel) ?? .info
    let message = String(cString: cMessage)
    pp_log_g(category, level, message)
}
