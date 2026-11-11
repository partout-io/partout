// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A default implementation of ``MessageHandler``.
public struct DefaultMessageHandler: MessageHandler {
    private let ctx: PartoutLoggerContext

    private let environment: TunnelEnvironment

    private let setLogLevel: @Sendable (DebugLog.Level) -> Void

    public init(
        _ ctx: PartoutLoggerContext,
        environment: TunnelEnvironment,
        setLogLevel: @escaping @Sendable (DebugLog.Level) -> Void = PartoutLogger.setMaxLevel
    ) {
        self.ctx = ctx
        self.environment = environment
        self.setLogLevel = setLogLevel
    }

    public func handleMessage(_ input: Message.Input) async throws -> Message.Output? {
        switch input {
        case .logLevel(let maxLevel):
            setLogLevel(maxLevel)
            return .logLevel(maxLevel: maxLevel)
        case .debugLog(let sinceLast, let maxLevel):
            let lines = ctx.logger.currentLogLines(sinceLast: sinceLast, maxLevel: maxLevel)
            return .debugLog(log: DebugLog(lines: lines))
        case .environment(let keys):
            let values = environment.snapshot(excludingKeys: keys)
            let env = StaticTunnelEnvironment(profileId: ctx.profileId, values: values)
            return .environment(env)
        }
    }
}
