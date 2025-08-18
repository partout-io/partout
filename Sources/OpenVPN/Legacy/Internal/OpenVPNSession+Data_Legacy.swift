// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
import PartoutCore
#endif

extension OpenVPNSession {
    func handleDataPackets(
        _ packets: [Data],
        to tunnel: TunnelInterface,
        dataChannel: DataChannel
    ) {
        Task {
            do {
                guard let decryptedPackets = try dataChannel.decrypt(packets: packets) else {
                    pp_log(ctx, .openvpn, .error, "Unable to decrypt packets, is SessionKey properly configured (dataPath, peerId)?")
                    return
                }
                guard !decryptedPackets.isEmpty else {
                    return
                }
                reportInboundDataCount(decryptedPackets.flatCount)
                try await tunnel.writePackets(decryptedPackets)
            } catch {
                if let nativeError = error.asNativeOpenVPNError {
                    throw nativeError
                }
                throw OpenVPNSessionError.recoverable(error)
            }
        }
    }

    func sendDataPackets(
        _ packets: [Data],
        to link: LinkInterface,
        dataChannel: DataChannel
    ) {
        Task {
            do {
                guard let encryptedPackets = try dataChannel.encrypt(packets: packets) else {
                    pp_log(ctx, .openvpn, .error, "Unable to encrypt packets, is SessionKey properly configured (dataPath, peerId)?")
                    return
                }
                guard !encryptedPackets.isEmpty else {
                    return
                }
                reportOutboundDataCount(encryptedPackets.flatCount)
                try await link.writePackets(encryptedPackets)
            } catch {
                if let nativeError = error.asNativeOpenVPNError {
                    throw nativeError
                }
                pp_log(ctx, .openvpn, .error, "Data: Failed LINK write during send data: \(error)")
                await shutdown(PartoutError(.linkFailure, error))
            }
        }
    }
}
