// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Pseudo-random number generator.
public protocol PRNGProtocol: Sendable {
    /// - Parameter length: The data length.
    /// - Returns: New data of the given length.
    func data(length: Int) -> Data
}
