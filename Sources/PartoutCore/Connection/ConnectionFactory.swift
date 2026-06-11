// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Spawns a ``Connection``.
public protocol ConnectionFactory: Sendable {
    func connection(for connectionModule: ConnectionModule, parameters: ConnectionParameters) throws -> Connection
}
