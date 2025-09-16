// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
internal import PartoutOpenVPN_ObjC
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension LegacyControlChannel {
    final class CryptSerializer: LegacyControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        private let encrypter: Encrypter

        private let decrypter: Decrypter

        private let headerLength: Int

        private var adLength: Int

        private let tagLength: Int

        private var currentReplayId: BidirectionalState<UInt32>

        private let timestamp: UInt32

        private let plain: PlainSerializer

        init(
            _ ctx: PartoutLoggerContext,
            with crypto: OpenVPNCryptoProtocol,
            key: OpenVPN.StaticKey
        ) throws {
            self.ctx = ctx
            let cryptoOptions = OpenVPNCryptoOptions(
                cipherAlgorithm: "AES-256-CTR",
                digestAlgorithm: "SHA256",
                cipherEncKey: key.cipherEncryptKey.legacyZData,
                cipherDecKey: key.cipherDecryptKey.legacyZData,
                hmacEncKey: key.hmacSendKey.legacyZData,
                hmacDecKey: key.hmacReceiveKey.legacyZData
            )
            try crypto.configure(with: cryptoOptions)
            encrypter = crypto.encrypter()
            decrypter = crypto.decrypter()

            headerLength = OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength
            adLength = headerLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength
            tagLength = crypto.tagLength()

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
            let data = try packet.serialized(with: encrypter, replayId: currentReplayId.outbound, timestamp: timestamp, adLength: adLength)
            currentReplayId.outbound += 1
            return data
        }

        // XXX: start/end are ignored, parses whole packet
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> LegacyPacket {
            let end = end ?? packet.count

            // data starts with (ad=(header + sessionId + replayId) + tag)
            guard end >= start + adLength + tagLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing AD+TAG")
            }

            let encryptedCount = packet.count - adLength
            var decryptedPacket = Data(count: decrypter.encryptionCapacity(withLength: encryptedCount))
            var decryptedCount = 0
            try packet.withUnsafeBytes {
                let src = $0.bytePointer
                var flags = CryptoFlags(iv: nil, ivLength: 0, ad: src, adLength: adLength, forTesting: false)
                try decryptedPacket.withUnsafeMutableBytes {
                    let dest = $0.bytePointer
                    try decrypter.decryptBytes(src + flags.adLength, length: encryptedCount, dest: dest + headerLength, destLength: &decryptedCount, flags: &flags)
                    memcpy(dest, src, headerLength)
                }
            }
            decryptedPacket.count = headerLength + decryptedCount

            // XXX: validate replay packet id

            do {
                return try plain.deserialize(data: decryptedPacket, start: 0, end: nil)
            } catch {
                pp_log(ctx, .openvpn, .fault, "Control: Channel failure: \(error)")
                throw error
            }
        }
    }
}
