// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// A default implementation of ``MessageHandler``.
public struct DefaultMessageHandler: MessageHandler {
    private let ctx: PartoutLoggerContext

    private let environment: TunnelEnvironment

    public init(_ ctx: PartoutLoggerContext, environment: TunnelEnvironment) {
        self.ctx = ctx
        self.environment = environment
    }

    public func handleMessage(_ input: Message.Input) async throws -> Message.Output? {
        switch input {
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
