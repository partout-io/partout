// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Spawns a stream to observe events about better network paths.
public protocol BetterPathStreamFactory: Sendable {
    nonisolated func newStream() -> PassthroughStream<Void>
}
