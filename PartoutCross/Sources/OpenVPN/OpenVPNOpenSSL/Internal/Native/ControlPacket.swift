//
//  ControlPacket.swift
//  Partout
//
//  Created by Davide De Rosa on 6/15/25.
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

internal import _PartoutOpenVPNOpenSSL_C
import Foundation
import PartoutCore

final class ControlPacket: PacketProtocol {
    let pkt: UnsafeMutablePointer<ctrl_pkt_t>

    var code: PacketCode {
        guard let code = PacketCode(rawValue: UInt8(pkt.pointee.code.rawValue)) else {
            assertionFailure("Unmapped packet code: \(pkt.pointee.code.rawValue)")
            return .unknown
        }
        return code
    }

    var key: UInt8 {
        pkt.pointee.key
    }

    var packetId: UInt32 {
        pkt.pointee.packet_id
    }

    var sessionId: Data {
        Data(bytesNoCopy: pkt.pointee.session_id, count: PacketSessionIdLength, deallocator: .none)
    }

    var payload: Data? {
        pkt.pointee.payload.map {
            Data(bytesNoCopy: $0, count: pkt.pointee.payload_len, deallocator: .none)
        }
    }

    var ackIds: [UInt32]? {
        pkt.pointee.ack_ids.map {
            Array(UnsafeBufferPointer(start: $0, count: pkt.pointee.ack_ids_len))
        }
    }

    var ackRemoteSessionId: Data? {
        pkt.pointee.payload.map {
            Data(bytesNoCopy: $0, count: pkt.pointee.payload_len, deallocator: .none)
        }
    }

    init(
        code: PacketCode, key: UInt8, packetId: UInt32,
        sessionId: Data, payload: Data?,
        ackIds: [UInt32]?, ackRemoteSessionId: Data?
    ) {
        pkt = ctrl_pkt_create(
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
            packetId: .max,
            sessionId: sessionId,
            payload: nil,
            ackIds: ackIds,
            ackRemoteSessionId: ackRemoteSessionId
        )
    }

    deinit {
        ctrl_pkt_free(pkt)
    }

    var isAck: Bool {
        packetId == .max
    }
}

extension ControlPacket: SensitiveDebugStringConvertible {
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
