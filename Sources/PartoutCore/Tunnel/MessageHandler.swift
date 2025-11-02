// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The I/O interface of a message handler.
public enum Message {
    public enum Input: Hashable, Codable, Sendable {
        case debugLog(sinceLast: TimeInterval, maxLevel: DebugLog.Level)

        case environment(excludingKeys: Set<String>? = nil)
    }

    public enum Output: Hashable, Codable, Sendable {
        case debugLog(log: DebugLog)

        case environment(StaticTunnelEnvironment)
    }
}

/// Asynchronous message handler for IPC.
public protocol MessageHandler: Sendable {
    func handleMessage(_ input: Message.Input) async throws -> Message.Output?
}

extension Message.Input {
    public static func environment(_ excludedKeys: [any TunnelEnvironmentKeyProtocol]) -> Self {
        Self.environment(excludingKeys: Set(excludedKeys.map(\.keyString)))
    }
}
