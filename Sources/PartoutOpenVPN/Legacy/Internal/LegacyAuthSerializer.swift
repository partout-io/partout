// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
internal import PartoutOpenVPN_ObjC
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension LegacyControlChannel {
    final class AuthSerializer: LegacyControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        private let encrypter: Encrypter

        private let decrypter: Decrypter

        private let prefixLength: Int

        private let hmacLength: Int

        private let authLength: Int

        private let preambleLength: Int

        private var currentReplayId: BidirectionalState<UInt32>

        private let timestamp: UInt32

        private let plain: PlainSerializer

        init(
            _ ctx: PartoutLoggerContext,
            with crypto: OpenVPNCryptoProtocol,
            key: OpenVPN.StaticKey,
            digest: OpenVPN.Digest
        ) throws {
            self.ctx = ctx
            let cryptoOptions = OpenVPNCryptoOptions(
                cipherAlgorithm: nil,
                digestAlgorithm: digest.rawValue,
                cipherEncKey: nil,
                cipherDecKey: nil,
                hmacEncKey: key.hmacSendKey.zData,
                hmacDecKey: key.hmacReceiveKey.zData
            )
            try crypto.configure(with: cryptoOptions)
            encrypter = crypto.encrypter()
            decrypter = crypto.decrypter()

            prefixLength = OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength
            hmacLength = crypto.digestLength()
            authLength = hmacLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength
            preambleLength = prefixLength + authLength

            currentReplayId = BidirectionalState(withResetValue: 1)
            timestamp = UInt32(Date().timeIntervalSince1970)
            plain = PlainSerializer(ctx)
        }

        func reset() {
        }

        func serialize(packet: LegacyPacket) throws -> Data {
            return try serialize(packet: packet, timestamp: timestamp)
        }

        func serialize(packet: LegacyPacket, timestamp: UInt32) throws -> Data {
            let data = try packet.serialized(withAuthenticator: encrypter, replayId: currentReplayId.outbound, timestamp: timestamp)
            currentReplayId.outbound += 1
            return data
        }

        // XXX: start/end are ignored, parses whole packet
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> LegacyPacket {
            let end = packet.count

            // data starts with (prefix=(header + sessionId) + auth=(hmac + replayId))
            guard end >= preambleLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing HMAC")
            }

            // needs a copy for swapping
            var authPacket = packet
            let authCount = authPacket.count
            try authPacket.withUnsafeMutableBytes {
                let ptr = $0.bytePointer
                PacketSwapCopy(ptr, packet, prefixLength, authLength)
                try decrypter.verifyBytes(ptr, length: authCount, flags: nil)
            }

            // XXX: validate replay packet id

            do {
                return try plain.deserialize(data: authPacket, start: authLength, end: nil)
            } catch {
                pp_log(ctx, .openvpn, .fault, "Control: Channel failure: \(error)")
                throw error
            }
        }
    }
}
