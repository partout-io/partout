// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable internal import PartoutOpenVPNLegacy
internal import _PartoutOpenVPNLegacy_ObjC
import XCTest

@OpenVPNActor
final class ControlChannelTests: XCTestCase {
    func test_givenChannel_whenHandleSequence_thenIsReordered() {
        let seq1: [UInt32] = [0, 5, 2, 1, 4, 3]
        let seq2: [UInt32] = [5, 2, 1, 9, 4, 3, 0, 8, 7, 10, 4, 3, 5, 6]
        let seq3: [UInt32] = [5, 2, 11, 1, 2, 9, 4, 5, 5, 3, 8, 0, 6, 8, 2, 7, 10, 4, 3, 5, 6]

        for seq in [seq1, seq2, seq3] {
            XCTAssertEqual(
                seq.sorted().unique(),
                handledSequence(seq.map(Wrapper.init)).map(\.packetId)
            )
        }
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

final class Wrapper: PacketProtocol {
    var packetId: UInt32

    init(_ packetId: UInt32) {
        self.packetId = packetId
    }
}
