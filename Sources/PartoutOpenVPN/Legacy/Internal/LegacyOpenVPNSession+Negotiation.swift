// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension LegacyOpenVPNSession {

    @discardableResult
    func startNegotiation(on link: LinkInterface) throws -> LegacyNegotiator {
        pp_log(ctx, .openvpn, .info, "Start negotiation")
        let neg = try newNegotiator(on: link)
        addNegotiator(neg)
        loopLink()
        try neg.start()
        return neg
    }

    func startRenegotiation(
        after negotiator: LegacyNegotiator,
        on link: LinkInterface,
        isServerInitiated: Bool
    ) throws -> LegacyNegotiator {
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
