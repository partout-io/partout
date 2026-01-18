// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Observes major events notified by a `OpenVPNSessionProtocol`.
protocol OpenVPNSessionDelegate: AnyObject, Sendable {

    /// Called after starting a session.
    ///
    /// - Parameter session: The originator.
    /// - Parameter remoteAddress: The address of the VPN server.
    /// - Parameter remoteProtocol: The endpoint protocol of the VPN server.
    /// - Parameter remoteOptions: The pulled tunnel settings.
    /// - Parameter remoteFd: The file descriptor of the underlying connection.
    func sessionDidStart(_ session: OpenVPNSessionProtocol, remoteAddress: String, remoteProtocol: EndpointProtocol, remoteOptions: OpenVPN.Configuration, remoteFd: UInt64?) async

    /// Called after stopping a session.
    ///
    /// - Parameter session: The originator.
    /// - Parameter error: An optional `Error` being the reason of the stop.
    func sessionDidStop(_ session: OpenVPNSessionProtocol, withError error: Error?) async

    /// Called when the data count gets a significant update.
    ///
    /// - Parameter session: The originator.
    /// - Parameter dataCount: The data count.
    func session(_ session: OpenVPNSessionProtocol, didUpdateDataCount dataCount: DataCount) async
}

/// Provides methods to set up and maintain an OpenVPN session.
protocol OpenVPNSessionProtocol: Sendable {

    /// Observe events with a `OpenVPNSessionDelegate`.
    func setDelegate(_ delegate: OpenVPNSessionDelegate) async

    /**
     Establishes the tunnel interface for this session. The interface must be up and running for sending and receiving packets.

     - Precondition: `tunnel` is an active network interface.
     - Postcondition: The VPN data channel is open.
     - Parameter tunnel: The `IOInterface` on which to exchange the VPN data traffic.
     */
    func setTunnel(_ tunnel: IOInterface) async

    /**
     Establishes the link interface for this session. The interface must be up and running for sending and receiving packets.

     - Precondition: `link` is an active network interface.
     - Postcondition: The VPN negotiation is started.
     - Parameter link: The `LinkInterface` on which to establish the VPN session.
     */
    func setLink(_ link: LinkInterface) async throws

    /// True if a link was set via ``setLink(_:)`` and is still alive.
    func hasLink() async -> Bool

    /**
     Shuts down the session with an optional `Error` reason. Does nothing if the session is already stopped or about to stop.

     - Parameters:
       - error: An optional `Error` being the reason of the shutdown.
       - timeout: The optional timeout in seconds.
     */
    func shutdown(_ error: Error?, timeout: TimeInterval?) async
}

extension OpenVPNSessionProtocol {
    func shutdown(_ error: Error?) async {
        await shutdown(error, timeout: nil)
    }
}
