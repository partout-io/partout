// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable internal import PartoutOpenVPNCross
import Foundation
import Testing

struct ControlPacketTests {
    @Test
    func givenControlPacket_whenSerialize_thenIsExpected() {
        let id: UInt32 = 0x1456
        let code: CPacketCode = .controlV1
        let key: UInt8 = 3
        let sessionId = Data(hex: "1122334455667788")
        let payload = Data(hex: "932748238742397591704891")

        let serialized = CControlPacket(
            code: code,
            key: key,
            sessionId: sessionId,
            packetId: id,
            payload: payload,
            ackIds: nil,
            ackRemoteSessionId: nil
        ).serialized()
        let expected = Data(hex: "2311223344556677880000001456932748238742397591704891")

        print(serialized.toHex())
        print(expected.toHex())

        #expect(serialized.toHex() == expected.toHex())
    }

    @Test
    func givenAckPacket_whenSerialize_thenIsExpected() {
        let acks: [UInt32] = [0xaa, 0xbb, 0xcc, 0xdd, 0xee]
        let key: UInt8 = 3
        let sessionId = Data(hex: "1122334455667788")
        let remoteSessionId = Data(hex: "a639328cbf03490e")

        let serialized = CControlPacket(
            key: key,
            sessionId: sessionId,
            ackIds: acks,
            ackRemoteSessionId: remoteSessionId
        ).serialized()
        let expected = Data(hex: "2b112233445566778805000000aa000000bb000000cc000000dd000000eea639328cbf03490e")

        print(serialized)
        print(expected)

        #expect(serialized.toHex() == expected.toHex())
    }
}
