// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
internal import PartoutOpenVPN_ObjC
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

@OpenVPNActor
final class LegacyControlChannel {
    private let ctx: PartoutLoggerContext

    private let prng: PRNGProtocol

    private let serializer: LegacyControlChannelSerializer

    private(set) var sessionId: Data?

    private(set) var remoteSessionId: Data? {
        didSet {
            if let id = remoteSessionId {
                pp_log(ctx, .openvpn, .info, "Control: Remote sessionId is \(id.toHex())")
            }
        }
    }

    private var queue: BidirectionalState<[LegacyPacket]>

    private var currentPacketId: BidirectionalState<UInt32>

    private var pendingAcks: Set<UInt32>

    private var plainBuffer: ZeroingData

    private var sentDates: [UInt32: Date]

    convenience init(_ ctx: PartoutLoggerContext, prng: PRNGProtocol) {
        self.init(ctx, prng: prng, serializer: PlainSerializer(ctx))
    }

    convenience init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        crypto: OpenVPNCryptoProtocol,
        authKey key: OpenVPN.StaticKey,
        digest: OpenVPN.Digest
    ) throws {
        self.init(ctx, prng: prng, serializer: try AuthSerializer(ctx, with: crypto, key: key, digest: digest))
    }

    convenience init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        crypto: OpenVPNCryptoProtocol,
        cryptKey key: OpenVPN.StaticKey
    ) throws {
        self.init(ctx, prng: prng, serializer: try CryptSerializer(ctx, with: crypto, key: key))
    }

    init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        serializer: LegacyControlChannelSerializer
    ) {
        self.ctx = ctx
        self.prng = prng
        self.serializer = serializer
        sessionId = nil
        remoteSessionId = nil
        queue = BidirectionalState(withResetValue: [])
        currentPacketId = BidirectionalState(withResetValue: 0)
        pendingAcks = []
        plainBuffer = Z(length: OpenVPNTLSOptionsDefaultBufferLength)
        sentDates = [:]
    }
}

extension LegacyControlChannel {
    func reset(forNewSession: Bool) {
        if forNewSession {
            sessionId = prng.data(length: OpenVPNPacketSessionIdLength)
            remoteSessionId = nil
        }
        queue.reset()
        currentPacketId.reset()
        pendingAcks.removeAll()
        plainBuffer.zero()
        sentDates.removeAll()
        serializer.reset()
    }

    func setRemoteSessionId(_ remoteSessionId: Data) {
        self.remoteSessionId = remoteSessionId
    }

    func readInboundPacket(withData data: Data, offset: Int) throws -> LegacyPacket {
        do {
            let packet = try serializer.deserialize(data: data, start: offset, end: nil)
            pp_log(ctx, .openvpn, .info, "Control: Read packet \(packet.asSensitiveBytes(ctx))")
            if let ackIds = packet.ackIds as? [UInt32], let ackRemoteSessionId = packet.ackRemoteSessionId {
                try readAcks(ackIds, acksRemoteSessionId: ackRemoteSessionId)
            }
            return packet
        } catch {
            pp_log(ctx, .openvpn, .fault, "Control: Channel failure: \(error)")
            throw error
        }
    }

    func enqueueInboundPacket(packet: LegacyPacket) -> [LegacyPacket] {
        var toHandle: [LegacyPacket] = []
        Self.enqueueInbound(&queue.inbound, &currentPacketId.inbound, packet) {
            toHandle.append($0)
        }
        return toHandle
    }

    static func enqueueInbound<T>(_ queue: inout [T], _ currentId: inout UInt32, _ packet: T, _ handle: (T) -> Void) where T: LegacyPacketProtocol {
        queue.append(packet)
        queue.sort {
            $0.packetId < $1.packetId
        }

        for packet in queue {
            if packet.packetId < currentId {
                queue.removeFirst()
                continue
            }
            if packet.packetId != currentId {
                return
            }

            handle(packet)
            currentId += 1
            queue.removeFirst()
        }
    }

    func enqueueOutboundPackets(withCode code: LegacyPacketCode, key: UInt8, payload: Data, maxPacketSize: Int) throws {
        guard let sessionId else {
            pp_log(ctx, .openvpn, .fault, "Control: Missing sessionId, do reset(forNewSession: true) first")
            throw OpenVPNSessionError.assertion
        }

        let oldIdOut = currentPacketId.outbound
        var queuedCount = 0
        var offset = 0

        repeat {
            let subPayloadLength = min(maxPacketSize, payload.count - offset)
            let subPayloadData = payload.subdata(offset: offset, count: subPayloadLength)
            let packet = LegacyPacket(
                code: code,
                key: key,
                sessionId: sessionId,
                packetId: currentPacketId.outbound,
                payload: subPayloadData,
                ackIds: nil,
                ackRemoteSessionId: nil
            )

            queue.outbound.append(packet)
            currentPacketId.outbound += 1
            offset += maxPacketSize
            queuedCount += subPayloadLength
        } while offset < payload.count

        assert(queuedCount == payload.count)

        // packet count
        let packetCount = currentPacketId.outbound - oldIdOut
        if packetCount > 1 {
            pp_log(ctx, .openvpn, .info, "Control: Enqueued \(packetCount) packets [\(oldIdOut)-\(currentPacketId.outbound - 1)]")
        } else {
            pp_log(ctx, .openvpn, .info, "Control: Enqueued 1 packet [\(oldIdOut)]")
        }
    }

    func writeOutboundPackets(resendAfter: TimeInterval) throws -> [Data] {
        var rawList: [Data] = []
        for packet in queue.outbound {
            if let sentDate = sentDates[packet.packetId] {
                let timeAgo = -sentDate.timeIntervalSinceNow
                guard timeAgo >= resendAfter else {
                    pp_log(ctx, .openvpn, .info, "Control: Skip writing packet with packetId \(packet.packetId) (sent on \(sentDate), \(timeAgo) seconds ago < \(resendAfter))")
                    continue
                }
            }

            pp_log(ctx, .openvpn, .info, "Control: Write control packet \(packet.asSensitiveBytes(ctx))")

            let raw = try serializer.serialize(packet: packet)
            rawList.append(raw)
            sentDates[packet.packetId] = Date()

            // track pending acks for sent packets
            pendingAcks.insert(packet.packetId)
        }
        return rawList
    }

    func hasPendingAcks() -> Bool {
        !pendingAcks.isEmpty
    }

    private func readAcks(_ packetIds: [UInt32], acksRemoteSessionId: Data) throws {
        guard let sessionId = sessionId else {
            throw OpenVPNSessionError.missingSessionId
        }
        guard acksRemoteSessionId == sessionId else {
            let error = OpenVPNSessionError.sessionMismatch
            pp_log(ctx, .openvpn, .fault, "Control: Ack session mismatch (\(acksRemoteSessionId.toHex()) != \(sessionId.toHex())): \(error)")
            throw error
        }

        // drop queued out packets if ack-ed
        queue.outbound.removeAll {
            return packetIds.contains($0.packetId)
        }

        // remove ack-ed packets from pending
        pendingAcks.subtract(packetIds)
    }

    func writeAcks(withKey key: UInt8, ackPacketIds: [UInt32], ackRemoteSessionId: Data) throws -> Data {
        guard let sessionId = sessionId else {
            throw OpenVPNSessionError.missingSessionId
        }
        let packet = LegacyPacket(
            key: key,
            sessionId: sessionId,
            ackIds: ackPacketIds as [NSNumber],
            ackRemoteSessionId: ackRemoteSessionId
        )
        pp_log(ctx, .openvpn, .info, "Control: Write ack packet \(packet.asSensitiveBytes(ctx))")
        return try serializer.serialize(packet: packet)
    }

    func currentControlData(withTLS tls: OpenVPNTLSProtocol) throws -> LegacyZD {
        var length = 0
        try tls.pullRawPlainText(plainBuffer.mutableBytes, length: &length)
        return plainBuffer.withOffset(0, length: length)
    }
}

extension LegacyControlChannel {
    final class PlainSerializer: LegacyControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        init(_ ctx: PartoutLoggerContext) {
            self.ctx = ctx
        }

        func reset() {
        }

        func serialize(packet: LegacyPacket) throws -> Data {
            return packet.serialized()
        }

        func deserialize(data packet: Data, start: Int, end: Int?) throws -> LegacyPacket {
            var offset = start
            let end = end ?? packet.count

            guard end >= offset + OpenVPNPacketOpcodeLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing opcode")
            }
            let codeValue = packet[offset] >> 3
            guard let code = LegacyPacketCode(rawValue: codeValue) else {
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
                guard let ackIds else {
                    throw OpenVPNSessionError.controlChannel(message: "Ack packet without ids")
                }
                guard let ackRemoteSessionId else {
                    throw OpenVPNSessionError.controlChannel(message: "Ack packet without remoteSessionId")
                }
                return LegacyPacket(
                    key: key,
                    sessionId: sessionId,
                    ackIds: ackIds as [NSNumber],
                    ackRemoteSessionId: ackRemoteSessionId
                )
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

            return LegacyPacket(
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
                hmacEncKey: key.hmacSendKey.legacyZData,
                hmacDecKey: key.hmacReceiveKey.legacyZData
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
