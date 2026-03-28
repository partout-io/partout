// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutOpenVPNConnection
import Testing

@OpenVPNActor
struct ControlChannelTests {
    @Test
    func givenChannel_whenHandleSequence_thenIsReordered() {
        let seq1: [UInt32] = [0, 5, 2, 1, 4, 3]
        let seq2: [UInt32] = [5, 2, 1, 9, 4, 3, 0, 8, 7, 10, 4, 3, 5, 6]
        let seq3: [UInt32] = [5, 2, 11, 1, 2, 9, 4, 5, 5, 3, 8, 0, 6, 8, 2, 7, 10, 4, 3, 5, 6]

        for seq in [seq1, seq2, seq3] {
            #expect(
                seq.sorted().unique()
                ==
                handledSequence(seq.map(Wrapper.init)).map(\.packetId)
            )
        }
    }

    @Test
    func givenTLSCryptV2Channel_whenWriteResetPacket_thenAppendsWrappedKey() throws {
        let wrappedKey = SecureData(Data([0xde, 0xad, 0xbe, 0xef]))
        let channel = try ControlChannel(
            .global,
            prng: MockPRNG(),
            cryptV2Key: .init(data: Data((0..<256).map(UInt8.init)), direction: .client),
            wrappedKey: wrappedKey
        )

        channel.reset(forNewSession: true)
        try channel.enqueueOutboundPackets(
            withCode: .hardResetClientV3,
            key: 0,
            payload: Data(),
            maxPacketSize: Constants.ControlChannel.maxPacketSize
        )

        let raw = try #require(channel.writeOutboundPackets(resendAfter: 0).first)
        #expect(raw.first.map { $0 >> 3 } == CPacketCode.hardResetClientV3.rawValue)
        #expect(raw.suffix(wrappedKey.count) == wrappedKey.toData())
    }

    @Test
    func givenTLSCryptV2Channel_whenSplitWKCControlPacket_thenOnlyLeadingPacketCarriesWrappedKey() throws {
        let wrappedKey = SecureData(Data([0xca, 0xfe, 0xba, 0xbe]))
        let channel = try ControlChannel(
            .global,
            prng: MockPRNG(),
            cryptV2Key: .init(data: Data((0..<256).map(UInt8.init)), direction: .client),
            wrappedKey: wrappedKey
        )
        let payload = Data(Array(repeating: 1, count: 6))

        channel.reset(forNewSession: true)
        try channel.enqueueOutboundPackets(
            withLeadingCode: .controlWkcV1,
            trailingCode: .controlV1,
            key: 0,
            payload: payload,
            leadingMaxPacketSize: 1,
            maxPacketSize: 4
        )

        let packets = try channel.writeOutboundPackets(resendAfter: 0)
        #expect(packets.count == 3)
        #expect(packets[0].first.map { $0 >> 3 } == CPacketCode.controlWkcV1.rawValue)
        #expect(packets[1].first.map { $0 >> 3 } == CPacketCode.controlV1.rawValue)
        #expect(packets[2].first.map { $0 >> 3 } == CPacketCode.controlV1.rawValue)
        #expect(packets[0].suffix(wrappedKey.count) == wrappedKey.toData())
        #expect(packets[1].suffix(wrappedKey.count) != wrappedKey.toData())
        #expect(packets[2].suffix(wrappedKey.count) != wrappedKey.toData())
    }
}

// MARK: - Helpers

private extension ControlChannelTests {
    func handledSequence(_ sequence: [Wrapper]) -> [Wrapper] {
        let sut = ControlChannel.self

        var queue: [Wrapper] = []
        var current: UInt32 = 0
        var handled: [Wrapper] = []
        for packet in sequence {
            sut.enqueueInbound(&queue, &current, packet) {
                handled.append($0)
            }
        }

        return handled
    }
}

final class Wrapper: CrossPacketProtocol {
    var packetId: UInt32

    init(_ packetId: UInt32) {
        self.packetId = packetId
    }
}

private final class MockPRNG: PRNGProtocol {
    func uint32() -> UInt32 {
        1
    }

    func data(length: Int) -> Data {
        Data(Array(repeating: 1, count: length))
    }

    func safeData(length: Int) -> SecureData {
        SecureData(data(length: length))
    }
}
