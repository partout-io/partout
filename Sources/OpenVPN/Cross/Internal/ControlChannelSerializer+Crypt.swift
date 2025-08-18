// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
import Foundation
#if !PARTOUT_STATIC
internal import _PartoutVendorsPortable
import PartoutCore
import PartoutOpenVPN
#endif

extension ControlChannel {
    final class CryptSerializer: ControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        private let ctr: pp_crypto_ctx

        private let headerLength: Int

        private var adLength: Int

        private let tagLength: Int

        private var currentReplayId: BidirectionalState<UInt32>

        private let timestamp: UInt32

        private let plain: PlainSerializer

        init(_ ctx: PartoutLoggerContext, key: OpenVPN.StaticKey) throws {
            self.ctx = ctx

            let ctr = {
                let keys = CryptoKeys(
                    cipher: .init(
                        encryptionKey: key.cipherEncryptKey.czData,
                        decryptionKey: key.cipherDecryptKey.czData
                    ),
                    digest: .init(
                        encryptionKey: key.hmacSendKey.czData,
                        decryptionKey: key.hmacReceiveKey.czData
                    )
                )
                let keysBridge = CryptoKeysBridge(keys: keys)
                return keysBridge.withUnsafeKeys {
                    pp_crypto_ctr_create(
                        "AES-256-CTR",
                        "SHA256",
                        Constants.ControlChannel.ctrTagLength,
                        Constants.ControlChannel.ctrPayloadLength,
                        $0
                    )
                }
            }()
            guard let ctr else {
                throw PPCryptoError.creation
            }
            self.ctr = ctr

            headerLength = OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength
            adLength = headerLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength
            tagLength = pp_crypto_meta_of(ctr).tag_len

            currentReplayId = BidirectionalState(withResetValue: 1)
            timestamp = UInt32(Date().timeIntervalSince1970)
            plain = PlainSerializer(ctx)
        }

        func reset() {
        }

        func serialize(packet: CControlPacket) throws -> Data {
            return try serialize(packet: packet, timestamp: timestamp)
        }

        func serialize(packet: CControlPacket, timestamp: UInt32) throws -> Data {
            let data = try packet.serialized(
                with: ctr,
                replayId: currentReplayId.outbound,
                timestamp: timestamp,
                function: openvpn_ctrl_serialize_crypt
            )
            currentReplayId.outbound += 1
            return data
        }

        // XXX: start/end are ignored, parses whole packet
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> CControlPacket {
            let end = end ?? packet.count

            // data starts with (ad=(header + sessionId + replayId) + tag)
            guard end >= start + adLength + tagLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing AD+TAG")
            }

            let encryptedCount = packet.count - adLength
            var decryptedPacket = Data(count: pp_crypto_encryption_capacity(ctr, encryptedCount))
            var decryptedCount = 0
            try packet.withUnsafeBytes {
                let src = $0.bytePointer
                var flags = pp_crypto_flags(
                    iv: nil,
                    iv_len: 0,
                    ad: src,
                    ad_len: adLength,
                    for_testing: 0
                )
                let dstBufCount = decryptedPacket.count
                try decryptedPacket.withUnsafeMutableBytes {
                    let dst = $0.bytePointer
                    var dec_error = PPCryptoErrorNone
                    decryptedCount = pp_crypto_decrypt(
                        ctr,
                        dst + headerLength,
                        dstBufCount - headerLength,
                        src + flags.ad_len,
                        encryptedCount,
                        &flags,
                        &dec_error
                    )
                    guard decryptedCount > 0 else {
                        throw CCryptoError(dec_error)
                    }
                    memcpy(dst, src, headerLength)
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
