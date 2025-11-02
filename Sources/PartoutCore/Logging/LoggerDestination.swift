// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A destination to append logs to.
public protocol LoggerDestination: Sendable {
    func append(_ level: DebugLog.Level, _ msg: String)
}
