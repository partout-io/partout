// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Represents a specific I/O interface meant to work at the link layer (e.g. TCP/IP).
public protocol LinkInterface: IOInterface {
    nonisolated var linkDescription: String { get }

    /// The literal address of the remote host.
    nonisolated var remoteAddress: String { get }

    /// The remote protocol.
    nonisolated var remoteProtocol: EndpointProtocol { get }

    /// Publishes when a better path is available.
    nonisolated var hasBetterPath: AsyncStream<Void> { get }

    /**
     Sets the handler for incoming packets. This only needs to be set once.

     - Parameter handler: The handler invoked whenever an array of `Data` packets is received, with an optional `Error` in case a network failure occurs.
     */
    func setReadHandler(_ handler: @escaping @Sendable ([Data]?, Error?) -> Void)

    /// Returns an upgraded link if available (e.g. when a better path exists).
    nonisolated func upgraded() async throws -> LinkInterface

    /// Shuts down the link.
    nonisolated func shutdown()
}

extension LinkInterface {

    /// The link type (UDP/TCP).
    public var linkType: IPSocketType {
        remoteProtocol.socketType
    }

    /// When `true`, packets delivery is guaranteed.
    public var isReliable: Bool {
        linkType.plainType == .tcp
    }
}

extension LinkInterface {
    public var linkDescription: String {
        "\(type(of: self))"
    }
}
