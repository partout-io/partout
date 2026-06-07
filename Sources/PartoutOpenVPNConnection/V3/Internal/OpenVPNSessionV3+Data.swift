// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPNSessionV3 {
    struct DataLink {
        let ctx: PartoutLoggerContext
        let looper: FdLooper
        let dataChannel: (UInt8) -> DataChannel?
        let reportInboundDataCount: (Int) -> Void
        let reportOutboundDataCount: (Int) -> Void

        func receive(_ packets: [Data], on key: UInt8) throws {
            do {
                guard let channel = dataChannel(key) else {
                    return
                }
                guard let decryptedPackets = try channel.decrypt(packets: packets) else {
                    pp_log(ctx, .openvpn, .error, "Unable to decrypt packets, is DataChannel properly configured?")
                    return
                }
                guard !decryptedPackets.isEmpty else {
                    return
                }
                reportInboundDataCount(decryptedPackets.flatCount)
                try looper.write(decryptedPackets, to: .tun)
            } catch let cError as CCryptoError {
                throw cError
            } catch let cError as CDataPathError {
                throw cError
            } catch {
                throw OpenVPNSessionError.recoverable(error)
            }
        }

        func send(_ packets: [Data], on key: UInt8) throws {
            do {
                guard let channel = dataChannel(key) else {
                    return
                }
                guard let encryptedPackets = try channel.encrypt(packets: packets) else {
                    pp_log(ctx, .openvpn, .error, "Unable to encrypt packets, is SessionKey properly configured (dataPath, peerId)?")
                    return
                }
                guard !encryptedPackets.isEmpty else {
                    return
                }
                reportOutboundDataCount(encryptedPackets.flatCount)
                try looper.write(encryptedPackets, to: .link)
            } catch let cError as CCryptoError {
                throw cError
            } catch let cError as CDataPathError {
                throw cError
            } catch {
                pp_log(ctx, .openvpn, .error, "Data: Failed LINK write during send data: \(error)")
                // FIXME: ###
//                Task {
//                    await shutdown(PartoutError(.ioFailure, error))
//                }
                throw error
            }
        }
    }
}
