// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Returns a stream to observe events about better network paths.
public typealias BetterPathBlock = @Sendable () throws -> PassthroughStream<Void>
