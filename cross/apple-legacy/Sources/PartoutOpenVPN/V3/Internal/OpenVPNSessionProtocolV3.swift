// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Observes major events notified by a `OpenVPNSessionProtocol`.
protocol OpenVPNSessionDelegateV3: AnyObject, Sendable {
    /// Called after starting a session.
    ///
    /// - Parameter session: The originator.
    /// - Parameter remoteEndpoint: The remote endpoint of the VPN server.
    /// - Parameter remoteOptions: The pulled tunnel settings.
    func sessionDidStart(_ session: OpenVPNSessionProtocolV3, remoteEndpoint: ExtendedEndpoint, remoteOptions: OpenVPN.Configuration)

    /// Called after stopping a session.
    ///
    /// - Parameter session: The originator.
    /// - Parameter error: An optional `Error` being the reason of the stop.
    func sessionDidStop(_ session: OpenVPNSessionProtocolV3, withError error: Error?)

    /// Called when the data count gets a significant update.
    ///
    /// - Parameter session: The originator.
    /// - Parameter dataCount: The data count.
    func session(_ session: OpenVPNSessionProtocolV3, didUpdateDataCount dataCount: DataCount)
}

/// Provides methods to set up and maintain an OpenVPN session.
protocol OpenVPNSessionProtocolV3: AnyObject, Sendable {
    /// Observe events with a `OpenVPNSessionDelegate`.
    func setDelegate(_ delegate: OpenVPNSessionDelegateV3)

    /**
     Establishes the link interface for this session. The interface must be up and running for sending and receiving packets.

     - Precondition: `link` is an active network interface.
     - Postcondition: The VPN negotiation is started.
     - Parameter link: The `LinkInterface` on which to establish the VPN session.
     - Parameter remoteEndpoint: The address and protocol of the remote server.
     */
    func setLink(_ link: LinkInterface, to remoteEndpoint: ExtendedEndpoint) async throws

    /// True if a link was set via ``setLink(_:)`` and is still alive.
    func hasLink() -> Bool

    /**
     Establishes the tunnel interface for this session. The interface must be up and running for sending and receiving packets.

     - Precondition: `tunnel` is an active network interface.
     - Postcondition: The VPN data channel is open.
     - Parameter tunnel: The `TunInterface` on which to exchange the VPN data traffic.
     */
    func setTunnel(_ tunnel: TunInterface) async throws

    /**
     Shuts down the session with an optional `Error` reason. Does nothing if the session is already stopped or about to stop.

     - Parameters:
       - error: An optional `Error` being the reason of the shutdown.
       - timeout: The optional timeout in seconds.
     */
    func shutdown(_ error: Error?, timeout: TimeInterval?) async
}

extension OpenVPNSessionProtocolV3 {
    func shutdown(_ error: Error?) async {
        await shutdown(error, timeout: nil)
    }
}
