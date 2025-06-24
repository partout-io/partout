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

import Foundation
import PartoutCore

// FIXME: ###, control_packet_t
final class ControlPacket: PacketProtocol {
    let code: PacketCode

    let key: UInt8

    let sessionId: Data

    let packetId: UInt32

    let payload: Data?

    let ackIds: [UInt32]?

    let ackRemoteSessionId: Data?

    init(
        code: PacketCode, key: UInt8, sessionId: Data, packetId: UInt32,
        payload: Data?, ackIds: [UInt32]?, ackRemoteSessionId: Data?
    ) {
        self.code = code
        self.key = key
        self.sessionId = sessionId
        self.packetId = packetId
        self.payload = payload
        self.ackIds = ackIds
        self.ackRemoteSessionId = ackRemoteSessionId
    }

    init(
        key: UInt8,
        sessionId: Data,
        ackIds: [UInt32],
        ackRemoteSessionId: Data
    ) {
        code = .ackV1
        self.key = key
        self.sessionId = sessionId
        packetId = .max
        payload = nil
        self.ackIds = ackIds
        self.ackRemoteSessionId = ackRemoteSessionId
    }

    var isAck: Bool {
        packetId == .max
    }
}

//extension ControlPacket: SensitiveDebugStringConvertible {
//    func debugDescription(withSensitiveData: Bool) -> String {
//        var msg: [String] = ["\(code) | \(key)"]
//        msg.append("sid: \(sessionId.toHex())")
//        if let ackIds, let ackRemoteSessionId {
//            msg.append("acks: {\(ackIds), \(ackRemoteSessionId.toHex())}")
//        }
//        if !isAck {
//            msg.append("pid: \(packetId)")
//        }
//        if let payload {
//            msg.append(payload.debugDescription(withSensitiveData: withSensitiveData))
//        }
//        return "{\(msg.joined(separator: ", "))}"
//    }
//}
