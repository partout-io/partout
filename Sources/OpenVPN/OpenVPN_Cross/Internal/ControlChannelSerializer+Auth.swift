//
//  ControlChannelSerializer+Auth.swift
//  Partout
//
//  Created by Davide De Rosa on 9/10/18.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

internal import _PartoutCryptoCore_C
internal import _PartoutOpenVPN_C
import _PartoutOpenVPNCore
import Foundation
import PartoutCore

extension ControlChannel {
    final class AuthSerializer: ControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        private let cbc: crypto_ctx

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
                    crypto_cbc_create(nil, digest.rawValue, $0)
                }
            }
            guard let cbc else {
                throw CryptoError.creation
            }
            self.cbc = cbc

            prefixLength = PacketOpcodeLength + PacketSessionIdLength
            hmacLength = crypto_meta(cbc).digest_len
            authLength = hmacLength + PacketReplayIdLength + PacketReplayTimestampLength
            preambleLength = prefixLength + authLength

            currentReplayId = BidirectionalState(withResetValue: 1)
            timestamp = UInt32(Date().timeIntervalSince1970)
            plain = PlainSerializer(ctx)
        }

        deinit {
            crypto_cbc_free(cbc)
        }

        func reset() {
        }

        func serialize(packet: CControlPacket) throws -> Data {
            return try serialize(packet: packet, timestamp: timestamp)
        }

        func serialize(packet: CControlPacket, timestamp: UInt32) throws -> Data {
            let data = try packet.serialized(
                with: cbc,
                replayId: currentReplayId.outbound,
                timestamp: timestamp,
                function: ctrl_pkt_serialize_auth
            )
            currentReplayId.outbound += 1
            return data
        }

        // XXX: start/end are ignored, parses whole packet
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> CControlPacket {
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
                    data_swap_copy(
                        dst.bytePointer,
                        src.bytePointer,
                        packet.count,
                        prefixLength,
                        authLength
                    )
                    var dec_error = CryptoErrorNone
                    guard crypto_verify(
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
