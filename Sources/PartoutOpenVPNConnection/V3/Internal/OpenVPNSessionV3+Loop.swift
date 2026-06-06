// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNConnection_C

extension OpenVPNSessionV3 {
    func receiveLink(_ packets: [Data]) throws {
        guard !isStopped, let looper else {
            return
        }

        reportLastReceivedDate()
        var dataPacketsByKey: [UInt8: [Data]] = [:]

        guard var negotiator = currentNegotiator else {
            pp_log(ctx, .openvpn, .fault, "No negotiator")
            throw OpenVPNSessionError.assertion
        }
        if negotiator.shouldRenegotiate() {
            negotiator = try startRenegotiation(after: negotiator, on: looper, isServerInitiated: false)
        }

        for packet in packets {
            guard let firstByte = packet.first else {
                pp_log(ctx, .openvpn, .error, "Dropped malformed packet (missing opcode)")
                continue
            }
            let codeValue = firstByte >> 3
            guard let code = CPacketCode(rawValue: codeValue) else {
                pp_log(ctx, .openvpn, .error, "Dropped malformed packet (unknown code: \(codeValue))")
                continue
            }

            var offset = 1
            if code == .dataV2 {
                guard packet.count >= offset + OpenVPNPacketPeerIdLength else {
                    pp_log(ctx, .openvpn, .error, "Dropped malformed packet (missing peerId)")
                    continue
                }
                offset += OpenVPNPacketPeerIdLength
            }

            if code == .dataV1 || code == .dataV2 {
                let key = firstByte & 0b111
                guard hasDataChannel(for: key) else {
                    pp_log(ctx, .openvpn, .error, "Data: Channel with key \(key) not found")
                    continue
                }

                // TODO: #140/notes, make more efficient with array reference
                var dataPackets = dataPacketsByKey[key] ?? [Data]()
                dataPackets.append(packet)
                dataPacketsByKey[key] = dataPackets

                continue
            }

            try processDataPackets(dataPacketsByKey)
            dataPacketsByKey.removeAll(keepingCapacity: true)

            let controlPacket: CrossPacket
            do {
                let parsedPacket = try negotiator.readInboundPacket(withData: packet, offset: 0)
                negotiator.handleAcks()
                if parsedPacket.code == .ackV1 {
                    continue
                }
                controlPacket = parsedPacket
            } catch {
                pp_log(ctx, .openvpn, .error, "Dropped malformed packet: \(error)")
                continue
            }
            switch code {
            case .hardResetServerV2:
                // HARD_RESET coming while connected
                guard !negotiator.isConnected else {
                    throw OpenVPNSessionError.recoverable(OpenVPNSessionError.staleSession)
                }
            case .softResetV1:
                if !negotiator.isRenegotiating {
                    negotiator = try startRenegotiation(after: negotiator, on: looper, isServerInitiated: true)
                }
            default:
                break
            }

            try negotiator.sendAck(for: controlPacket, to: looper)

            let pendingInboundQueue = negotiator.enqueueInboundPacket(packet: controlPacket)
            pp_log(ctx, .openvpn, .debug, "Pending inbound queue: \(pendingInboundQueue.map(\.packetId))")
            for inboundPacket in pendingInboundQueue {
                pp_log(ctx, .openvpn, .debug, "Handle packet: \(inboundPacket.packetId)")
                try negotiator.handleControlPacket(inboundPacket)
            }
        }

        try processDataPackets(dataPacketsByKey)
    }

    func receiveTunnel(_ packets: [Data]) throws {
        guard !isStopped else {
            return
        }
        guard let negotiator = currentNegotiator else {
            pp_log(ctx, .openvpn, .fault, "No negotiator")
            throw OpenVPNSessionError.assertion
        }
        guard negotiator.isConnected, let currentDataChannel else {
            return
        }

        try checkPingTimeout()

        try sendDataPackets(
            packets,
            to: negotiator.looper,
            dataChannel: currentDataChannel
        )
    }
}

private extension OpenVPNSessionV3 {
    @inline(always)
    func processDataPackets(_ dataPacketsByKey: [UInt8: [Data]]) throws {
        guard !dataPacketsByKey.isEmpty else { return }
        guard let looper else { return }
        for (key, dataPackets) in dataPacketsByKey {
            guard let dataChannel = dataChannel(for: key) else {
                pp_log(ctx, .openvpn, .error, "Accounted a data packet for which the cryptographic key hadn't been found")
                continue
            }
            try handleDataPackets(
                dataPackets,
                to: looper,
                dataChannel: dataChannel
            )
        }
    }
}
