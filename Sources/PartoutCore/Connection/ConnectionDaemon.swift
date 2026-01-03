// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Connection daemon handling async I/O.
public protocol ConnectionDaemon: Sendable {
    nonisolated var profile: Profile { get }

    func start() async throws

    func stop() async

    func hold() async

    func sendMessage(_ message: Message.Input) async throws -> Message.Output?
}
