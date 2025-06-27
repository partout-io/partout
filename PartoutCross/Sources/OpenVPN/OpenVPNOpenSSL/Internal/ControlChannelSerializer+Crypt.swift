//
//  ControlChannelSerializer+Crypt.swift
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

internal import _PartoutCryptoOpenSSL_Cross
import _PartoutOpenVPNCore
internal import _PartoutOpenVPNOpenSSL_C
import Foundation
import PartoutCore

private let CryptoCTRTagLength = 32

private let CryptoCTRPayloadLength = PacketOpcodeLength + PacketSessionIdLength + PacketReplayIdLength + PacketReplayTimestampLength

extension ControlChannel {
    final class CryptSerializer: ControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        private let ctr: UnsafeMutablePointer<crypto_ctr_t>

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
                var cKeys = CryptoKeysBridge(keys: keys).cKeys
                return crypto_ctr_create(
                    "AES-256-CTR",
                    "SHA256",
                    CryptoCTRTagLength,
                    CryptoCTRPayloadLength,
                    &cKeys
                )
            }()
            guard let ctr else {
                throw CryptoError.creation
            }
            self.ctr = ctr

            headerLength = PacketOpcodeLength + PacketSessionIdLength
            adLength = headerLength + PacketReplayIdLength + PacketReplayTimestampLength
            tagLength = ctr.pointee.crypto.meta.tag_len

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
            let data = try withUnsafeMutablePointer(to: &ctr.pointee.crypto) {
                try packet.serialized(
                    withEncrypter: $0,
                    replayId: currentReplayId.outbound,
                    timestamp: timestamp
                )
            }
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
            var decryptedPacket = Data(count: ctr.pointee.crypto.meta.encryption_capacity(ctr, encryptedCount))
            var decryptedCount = 0
            try packet.withUnsafeBytes {
                let src = $0.bytePointer
                var flags = crypto_flags_t(
                    iv: nil,
                    iv_len: 0,
                    ad: src,
                    ad_len: adLength,
                    for_testing: 0
                )
                try decryptedPacket.withUnsafeMutableBytes {
                    let dest = $0.bytePointer
                    var dec_error = CryptoErrorNone
                    guard ctr.pointee.crypto.decrypter.decrypt(
                        ctr,
                        dest + headerLength,
                        &decryptedCount,
                        src + flags.ad_len,
                        encryptedCount,
                        &flags,
                        &dec_error
                    ) else {
                        // FIXME: ###, map enc_error to CryptoError
//                        throw CryptoError(dec_error)
                        throw CryptoError.encryption
                    }
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
