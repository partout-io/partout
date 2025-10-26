// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Returns a ``PassthroughStream`` to observe events about better network paths.
public typealias BetterPathBlock = @Sendable () throws -> PassthroughStream<Void>
