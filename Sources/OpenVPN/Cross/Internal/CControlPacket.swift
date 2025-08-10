// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
import Foundation
import PartoutCore

final class CControlPacket {
    let pkt: UnsafeMutablePointer<openvpn_ctrl_pkt>

    let code: CPacketCode

    var key: UInt8 {
        pkt.pointee.key
    }

    let sessionId: Data

    var packetId: UInt32 {
        pkt.pointee.openvpn_packet_id
    }

    let payload: Data?

    let ackIds: [UInt32]?

    let ackRemoteSessionId: Data?

    init(
        code: CPacketCode, key: UInt8, sessionId: Data,
        packetId: UInt32, payload: Data?,
        ackIds: [UInt32]?, ackRemoteSessionId: Data?
    ) {
        let pkt = openvpn_ctrl_pkt_create(
            code.native,
            key,
            packetId,
            [UInt8](sessionId),
            payload.map { [UInt8]($0) } ?? nil,
            payload?.count ?? 0,
            ackIds.map { [UInt32]($0) } ?? nil,
            ackIds?.count ?? 0,
            ackRemoteSessionId.map { [UInt8]($0) } ?? nil
        )

        self.pkt = pkt
        self.code = code
        self.sessionId = Data(bytesNoCopy: pkt.pointee.session_id, count: _PartoutOpenVPN_C.OpenVPNPacketSessionIdLength, deallocator: .none)
        self.payload = pkt.pointee.payload.map {
            Data(bytesNoCopy: $0, count: pkt.pointee.payload_len, deallocator: .none)
        }
        self.ackIds = pkt.pointee.ack_ids.map {
            Array(UnsafeBufferPointer(start: $0, count: pkt.pointee.ack_ids_len))
        }
        self.ackRemoteSessionId = pkt.pointee.ack_remote_session_id.map {
            Data(bytesNoCopy: $0, count: _PartoutOpenVPN_C.OpenVPNPacketSessionIdLength, deallocator: .none)
        }
    }

    convenience init(
        key: UInt8,
        sessionId: Data,
        ackIds: [UInt32],
        ackRemoteSessionId: Data
    ) {
        self.init(
            code: .ackV1,
            key: key,
            sessionId: sessionId,
            packetId: .max,
            payload: nil,
            ackIds: ackIds,
            ackRemoteSessionId: ackRemoteSessionId
        )
    }

    deinit {
        openvpn_ctrl_pkt_free(pkt)
    }

    var isAck: Bool {
        packetId == .max
    }
}

extension CControlPacket: SensitiveDebugStringConvertible {
    func debugDescription(withSensitiveData: Bool) -> String {
        var msg: [String] = ["\(code) | \(key)"]
        msg.append("sid: \(sessionId.toHex())")
        if let ackIds, let ackRemoteSessionId {
            msg.append("acks: {\(ackIds), \(ackRemoteSessionId.toHex())}")
        }
        if !isAck {
            msg.append("pid: \(packetId)")
        }
        if let payload {
            msg.append(payload.debugDescription(withSensitiveData: withSensitiveData))
        }
        return "{\(msg.joined(separator: ", "))}"
    }
}
