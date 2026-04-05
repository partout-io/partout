// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNConnection_C

@OpenVPNActor
final class ControlChannel {
    private let ctx: PartoutLoggerContext

    private let prng: PRNGProtocol

    private let serializer: ControlChannelSerializer

    private(set) var sessionId: Data?

    private(set) var remoteSessionId: Data? {
        didSet {
            if let id = remoteSessionId {
                pp_log(ctx, .openvpn, .info, "Control: Remote sessionId is \(id.toHex())")
            }
        }
    }

    private var queue: BidirectionalState<[CrossPacket]>

    private var currentPacketId: BidirectionalState<UInt32>

    private var pendingAcks: Set<UInt32>

    private var sentDates: [UInt32: Date]

    convenience init(_ ctx: PartoutLoggerContext, prng: PRNGProtocol) {
        self.init(ctx, prng: prng, serializer: PlainSerializer(ctx))
    }

    init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        serializer: ControlChannelSerializer
    ) {
        self.ctx = ctx
        self.prng = prng
        self.serializer = serializer
        sessionId = nil
        remoteSessionId = nil
        queue = BidirectionalState(withResetValue: [])
        currentPacketId = BidirectionalState(withResetValue: 0)
        pendingAcks = []
        sentDates = [:]
    }
}

extension ControlChannel {
    func reset(forNewSession: Bool) {
        if forNewSession {
            sessionId = prng.data(length: OpenVPNPacketSessionIdLength)
            remoteSessionId = nil
        }
        queue.reset()
        currentPacketId.reset()
        pendingAcks.removeAll()
        sentDates.removeAll()
        serializer.reset()
    }

    func setRemoteSessionId(_ remoteSessionId: Data) {
        self.remoteSessionId = remoteSessionId
    }

    func readInboundPacket(withData data: Data, offset: Int) throws -> CrossPacket {
        do {
            let packet = try serializer.deserialize(data: data, start: offset, end: nil)
            pp_log(ctx, .openvpn, .info, "Control: Read packet \(packet.asSensitiveBytes(ctx))")
            if let ackIds = packet.ackIds, let ackRemoteSessionId = packet.ackRemoteSessionId {
                try readAcks(ackIds, acksRemoteSessionId: ackRemoteSessionId)
            }
            return packet
        } catch {
            pp_log(ctx, .openvpn, .fault, "Control: Channel failure: \(error)")
            throw error
        }
    }

    func enqueueInboundPacket(packet: CrossPacket) -> [CrossPacket] {
        var toHandle: [CrossPacket] = []
        Self.enqueueInbound(&queue.inbound, &currentPacketId.inbound, packet) {
            toHandle.append($0)
        }
        return toHandle
    }

    static func enqueueInbound<T>(_ queue: inout [T], _ currentId: inout UInt32, _ packet: T, _ handle: (T) -> Void) where T: CrossPacketProtocol {
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

    func enqueueOutboundPackets(withCode code: CrossPacketCode, key: UInt8, payload: Data, maxPayloadBytesPerPacket: Int) throws {
        try enqueueOutboundPackets(
            withLeadingCode: code,
            trailingCode: code,
            key: key,
            payload: payload,
            leadingPayloadByteLimit: maxPayloadBytesPerPacket,
            trailingPayloadByteLimit: maxPayloadBytesPerPacket
        )
    }

    func enqueueOutboundPackets(
        withLeadingCode leadingCode: CrossPacketCode,
        trailingCode: CrossPacketCode,
        key: UInt8,
        payload: Data,
        leadingPayloadByteLimit: Int,
        trailingPayloadByteLimit: Int
    ) throws {
        guard let sessionId else {
            pp_log(ctx, .openvpn, .fault, "Control: Missing sessionId, do reset(forNewSession: true) first")
            throw OpenVPNSessionError.assertion
        }
        if payload.count > 0 {
            guard leadingPayloadByteLimit > 0 else {
                throw OpenVPNSessionError.controlChannel(message: "Leading control payload budget must be positive")
            }
            guard trailingPayloadByteLimit > 0 else {
                throw OpenVPNSessionError.controlChannel(message: "Trailing control payload budget must be positive")
            }
        }

        let oldIdOut = currentPacketId.outbound
        var queuedPayloadByteCount = 0
        var offset = 0
        var isLeadingPacket = true

        while true {
            let packetCode = isLeadingPacket ? leadingCode : trailingCode
            let payloadByteLimit = isLeadingPacket ? leadingPayloadByteLimit : trailingPayloadByteLimit
            let remainingPayloadLength = payload.count - offset
            let subPayloadLength = min(payloadByteLimit, remainingPayloadLength)
            let subPayloadData = payload.subdata(offset: offset, count: subPayloadLength)
            let packet = CrossPacket(
                code: packetCode,
                key: key,
                sessionId: sessionId,
                packetId: currentPacketId.outbound,
                payload: subPayloadData,
                ackIds: nil,
                ackRemoteSessionId: nil
            )

            queue.outbound.append(packet)
            currentPacketId.outbound += 1
            offset += subPayloadLength
            queuedPayloadByteCount += subPayloadLength
            guard offset < payload.count else { break }
            isLeadingPacket = false
        }

        assert(queuedPayloadByteCount == payload.count)

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
        let packet = CrossPacket(
            key: key,
            sessionId: sessionId,
            ackIds: ackPacketIds,
            ackRemoteSessionId: ackRemoteSessionId
        )
        pp_log(ctx, .openvpn, .info, "Control: Write ack packet \(packet.asSensitiveBytes(ctx))")
        return try serializer.serialize(packet: packet)
    }

    func currentControlData(withTLS tls: TLSProtocol) throws -> CrossZD {
        CZ(try tls.pullPlainText())
    }
}
