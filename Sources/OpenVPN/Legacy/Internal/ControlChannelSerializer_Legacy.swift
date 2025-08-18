// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
internal import _PartoutCryptoOpenSSL_ObjC
internal import _PartoutOpenVPNLegacy_ObjC
import PartoutCore
import PartoutOpenVPN
#endif

protocol ControlChannelSerializer {
    func reset()

    func serialize(packet: ControlPacket) throws -> Data

    func deserialize(data: Data, start: Int, end: Int?) throws -> ControlPacket
}

extension ControlChannel {
    final class PlainSerializer: ControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        init(_ ctx: PartoutLoggerContext) {
            self.ctx = ctx
        }

        func reset() {
        }

        func serialize(packet: ControlPacket) throws -> Data {
            return packet.serialized()
        }

        func deserialize(data packet: Data, start: Int, end: Int?) throws -> ControlPacket {
            var offset = start
            let end = end ?? packet.count

            guard end >= offset + OpenVPNPacketOpcodeLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing opcode")
            }
            let codeValue = packet[offset] >> 3
            guard let code = PacketCode(rawValue: codeValue) else {
                throw OpenVPNSessionError.controlChannel(message: "Unknown code: \(codeValue))")
            }
            let key = packet[offset] & 0b111
            offset += OpenVPNPacketOpcodeLength

            pp_log(ctx, .openvpn, .info, "Control: Try read packet with code \(code.debugDescription) and key \(key)")

            guard end >= offset + OpenVPNPacketSessionIdLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing sessionId")
            }
            let sessionId = packet.subdata(offset: offset, count: OpenVPNPacketSessionIdLength)
            offset += OpenVPNPacketSessionIdLength

            guard end >= offset + 1 else {
                throw OpenVPNSessionError.controlChannel(message: "Missing ackSize")
            }
            let ackSize = packet[offset]
            offset += 1

            var ackIds: [UInt32]?
            var ackRemoteSessionId: Data?
            if ackSize > 0 {
                guard end >= (offset + Int(ackSize) * OpenVPNPacketIdLength) else {
                    throw OpenVPNSessionError.controlChannel(message: "Missing acks")
                }
                var ids: [UInt32] = []
                for _ in 0..<ackSize {
                    let id = packet.networkUInt32Value(from: offset)
                    ids.append(id)
                    offset += OpenVPNPacketIdLength
                }

                guard end >= offset + OpenVPNPacketSessionIdLength else {
                    throw OpenVPNSessionError.controlChannel(message: "Missing remoteSessionId")
                }
                let remoteSessionId = packet.subdata(offset: offset, count: OpenVPNPacketSessionIdLength)
                offset += OpenVPNPacketSessionIdLength

                ackIds = ids
                ackRemoteSessionId = remoteSessionId
            }

            if code == .ackV1 {
                guard let ackIds = ackIds else {
                    throw OpenVPNSessionError.controlChannel(message: "Ack packet without ids")
                }
                guard let ackRemoteSessionId = ackRemoteSessionId else {
                    throw OpenVPNSessionError.controlChannel(message: "Ack packet without remoteSessionId")
                }
                return ControlPacket(key: key, sessionId: sessionId, ackIds: ackIds as [NSNumber], ackRemoteSessionId: ackRemoteSessionId)
            }

            guard end >= offset + OpenVPNPacketIdLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing packetId")
            }
            let packetId = packet.networkUInt32Value(from: offset)
            offset += OpenVPNPacketIdLength

            var payload: Data?
            if offset < end {
                payload = packet.subdata(in: offset..<end)
            }

            return ControlPacket(
                code: code,
                key: key,
                sessionId: sessionId,
                packetId: packetId,
                payload: payload,
                ackIds: ackIds.map { $0 as [NSNumber] },
                ackRemoteSessionId: ackRemoteSessionId
            )
        }
    }
}

extension ControlChannel {
    final class AuthSerializer: ControlChannelSerializer {
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

        init(_ ctx: PartoutLoggerContext, with crypto: OpenVPNCryptoProtocol, key: OpenVPN.StaticKey, digest: OpenVPN.Digest) throws {
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

        func serialize(packet: ControlPacket) throws -> Data {
            return try serialize(packet: packet, timestamp: timestamp)
        }

        func serialize(packet: ControlPacket, timestamp: UInt32) throws -> Data {
            let data = try packet.serialized(withAuthenticator: encrypter, replayId: currentReplayId.outbound, timestamp: timestamp)
            currentReplayId.outbound += 1
            return data
        }

        // XXX: start/end are ignored, parses whole packet
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> ControlPacket {
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

extension ControlChannel {
    final class CryptSerializer: ControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        private let encrypter: Encrypter

        private let decrypter: Decrypter

        private let headerLength: Int

        private var adLength: Int

        private let tagLength: Int

        private var currentReplayId: BidirectionalState<UInt32>

        private let timestamp: UInt32

        private let plain: PlainSerializer

        init(_ ctx: PartoutLoggerContext, with crypto: OpenVPNCryptoProtocol, key: OpenVPN.StaticKey) throws {
            self.ctx = ctx
            let cryptoOptions = OpenVPNCryptoOptions(
                cipherAlgorithm: "AES-256-CTR",
                digestAlgorithm: "SHA256",
                cipherEncKey: key.cipherEncryptKey.zData,
                cipherDecKey: key.cipherDecryptKey.zData,
                hmacEncKey: key.hmacSendKey.zData,
                hmacDecKey: key.hmacReceiveKey.zData
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

        func serialize(packet: ControlPacket) throws -> Data {
            return try serialize(packet: packet, timestamp: timestamp)
        }

        func serialize(packet: ControlPacket, timestamp: UInt32) throws -> Data {
            let data = try packet.serialized(with: encrypter, replayId: currentReplayId.outbound, timestamp: timestamp, adLength: adLength)
            currentReplayId.outbound += 1
            return data
        }

        // XXX: start/end are ignored, parses whole packet
        func deserialize(data packet: Data, start: Int, end: Int?) throws -> ControlPacket {
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
