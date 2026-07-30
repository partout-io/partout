// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPNSessionV3 {
    @discardableResult
    func startNegotiation(on looper: FdLooper, remoteEndpoint: ExtendedEndpoint) throws -> NegotiatorV3 {
        pp_log(ctx, .openvpn, .info, "Start negotiation")
        let neg = try newNegotiator(on: looper, remoteEndpoint: remoteEndpoint)
        addNegotiator(neg)
        try neg.start()
        return neg
    }

    func startRenegotiation(
        after negotiator: NegotiatorV3,
        on looper: FdLooper,
        isServerInitiated: Bool
    ) throws -> NegotiatorV3 {
        guard !negotiator.isRenegotiating else {
            pp_log(ctx, .openvpn, .error, "Renegotiation already in progress")
            return negotiator
        }
        if isServerInitiated {
            pp_log(ctx, .openvpn, .notice, "Renegotiation request from server")
        } else {
            pp_log(ctx, .openvpn, .notice, "Renegotiation request from client")
        }
        let neg = negotiator.forRenegotiation(initiatedBy: isServerInitiated ? .server : .client)
        addNegotiator(neg)
        try neg.start()
        return neg
    }
}
