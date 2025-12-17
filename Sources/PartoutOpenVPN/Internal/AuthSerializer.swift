// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C

extension ControlChannel {
    final class AuthSerializer: ControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        private let cbc: pp_crypto_ctx

        private let prefixLength: Int

        private let hmacLength: Int

        private let authLength: Int

        private let preambleLength: Int

        private var currentReplayId: BidirectionalState<UInt32>

        private let timestamp: UInt32

        private let plain: PlainSerializer

        init(
            _ ctx: PartoutLoggerContext,
            digest: OpenVPN.Digest,
            key: OpenVPN.StaticKey
        ) throws {
            self.ctx = ctx

            let cbc = digest.rawValue.withCString { _ in
                let keys = CryptoKeys(
                    cipher: nil,
                    digest: .init(
                        encryptionKey: key.hmacSendKey.czData,
                        decryptionKey: key.hmacReceiveKey.czData
                    )
                )
                let keysBridge = CryptoKeysBridge(keys: keys)
                return keysBridge.withUnsafeKeys {
                    pp_crypto_cbc_create(nil, digest.rawValue, $0)
                }
            }
            guard let cbc else {
                throw PPCryptoError.creation
            }
            self.cbc = cbc

            prefixLength = OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength
            hmacLength = pp_crypto_meta_of(cbc).digest_len
            authLength = hmacLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength
            preambleLength = prefixLength + authLength

            currentReplayId = BidirectionalState(withResetValue: 1)
            timestamp = UInt32(Date().timeIntervalSince1970)
            plain = PlainSerializer(ctx)
        }

        deinit {
            pp_crypto_cbc_free(cbc)
        }

        func reset() {
        }

        func serialize(packet: CrossPacket) throws -> Data {
            return try serialize(packet: packet, timestamp: timestamp)
        }

        func serialize(packet: CrossPacket, timestamp: UInt32) throws -> Data {
            let data = try packet.serialized(
                with: cbc,
                replayId: currentReplayId.outbound,
                timestamp: timestamp,
                function: openvpn_ctrl_serialize_auth
            )
            currentReplayId.outbound += 1
            return data
        }

        // XXX: start/end are ignored, parses whole packet
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> CrossPacket {
            let end = packet.count

            // data starts with (prefix=(header + sessionId) + auth=(hmac + replayId))
            guard end >= preambleLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing HMAC")
            }

            // needs a copy for swapping
            var authPacket = packet
            let authCount = authPacket.count
            try authPacket.withUnsafeMutableBytes { dst in
                try packet.withUnsafeBytes { src in
                    openvpn_data_swap_copy(
                        dst.bytePointer,
                        src.bytePointer,
                        packet.count,
                        prefixLength,
                        authLength
                    )
                    var dec_error = PPCryptoErrorNone
                    guard pp_crypto_verify(
                        cbc,
                        dst.bytePointer,
                        authCount,
                        &dec_error
                    ) else {
                        throw CCryptoError(dec_error)
                    }
                }
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
