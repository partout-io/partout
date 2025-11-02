// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Observes activity to eventually return a ``LinkInterface``.
public protocol LinkObserver {

    /// Waits until the link is active.
    ///
    /// - Parameter timeout: The timeout for link activity.
    func waitForActivity(timeout: Int) async throws -> LinkInterface
}
