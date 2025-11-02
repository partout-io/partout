// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Generalizes the creation of network interfaces.
public protocol NetworkInterfaceFactory: Sendable {

    /// Returns a `LinkObserver` to establish a link to the specified endpoint.
    ///
    /// - Parameter endpoint: The endpoint to connect to.
    func linkObserver(to endpoint: ExtendedEndpoint) throws -> LinkObserver
}
