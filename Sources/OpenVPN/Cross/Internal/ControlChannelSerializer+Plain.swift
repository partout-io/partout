//
//  ControlChannelSerializer+Plain.swift
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

internal import _PartoutOpenVPN_C
internal import _PartoutVendorsPortable
import Foundation
import PartoutCore
import PartoutOpenVPN

extension ControlChannel {
    final class PlainSerializer: ControlChannelSerializer {
        private let ctx: PartoutLoggerContext

        init(_ ctx: PartoutLoggerContext) {
            self.ctx = ctx
        }

        func reset() {
        }

        func serialize(packet: CControlPacket) throws -> Data {
            return packet.serialized()
        }

        func deserialize(data packet: Data, start: Int, end: Int?) throws -> CControlPacket {
            var offset = start
            let end = end ?? packet.count

            guard end >= offset + PacketOpcodeLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing opcode")
            }
            let codeValue = packet[offset] >> 3
            guard let code = CPacketCode(rawValue: codeValue) else {
                throw OpenVPNSessionError.controlChannel(message: "Unknown code: \(codeValue))")
            }
            let key = packet[offset] & 0b111
            offset += PacketOpcodeLength

            pp_log(ctx, .openvpn, .info, "Control: Try read packet with code \(code.debugDescription) and key \(key)")

            guard end >= offset + PacketSessionIdLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing sessionId")
            }
            let sessionId = packet.subdata(offset: offset, count: PacketSessionIdLength)
            offset += PacketSessionIdLength

            guard end >= offset + 1 else {
                throw OpenVPNSessionError.controlChannel(message: "Missing ackSize")
            }
            let ackSize = packet[offset]
            offset += 1

            var ackIds: [UInt32]?
            var ackRemoteSessionId: Data?
            if ackSize > 0 {
                guard end >= (offset + Int(ackSize) * PacketIdLength) else {
                    throw OpenVPNSessionError.controlChannel(message: "Missing acks")
                }
                var ids: [UInt32] = []
                for _ in 0..<ackSize {
                    let id = packet.networkUInt32Value(from: offset)
                    ids.append(id)
                    offset += PacketIdLength
                }

                guard end >= offset + PacketSessionIdLength else {
                    throw OpenVPNSessionError.controlChannel(message: "Missing remoteSessionId")
                }
                let remoteSessionId = packet.subdata(offset: offset, count: PacketSessionIdLength)
                offset += PacketSessionIdLength

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
                return CControlPacket(
                    key: key,
                    sessionId: sessionId,
                    ackIds: ackIds,
                    ackRemoteSessionId: ackRemoteSessionId
                )
            }

            guard end >= offset + PacketIdLength else {
                throw OpenVPNSessionError.controlChannel(message: "Missing packetId")
            }
            let packetId = packet.networkUInt32Value(from: offset)
            offset += PacketIdLength

            var payload: Data?
            if offset < end {
                payload = packet.subdata(in: offset..<end)
            }

            return CControlPacket(
                code: code,
                key: key,
                sessionId: sessionId,
                packetId: packetId,
                payload: payload,
                ackIds: ackIds,
                ackRemoteSessionId: ackRemoteSessionId
            )
        }
    }
}
