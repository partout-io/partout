//
//  PacketProcessorTests.swift
//  Partout
//
//  Created by Davide De Rosa on 11/4/22.
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

import _PartoutOpenVPNCore
@testable internal import _PartoutOpenVPN_Cross
import Foundation
import PartoutCore
import Testing

struct PacketProcessorTests {
    private let prng = SimplePRNG()

    private let rndLength = 237

    private let mask = SecureData("f76dab30")!

    // MARK: - Raw

    @Test
    func givenProcessor_whenMask_thenIsExpected() {
        let sut = PacketProcessor(method: .xormask(mask: mask))
        let data = prng.data(length: rndLength)
        let maskData = mask.czData
        let processed = sut.processPacket(data, direction: .inbound)
        print(data.toHex())
        print(processed.toHex())
        for (i, byte) in processed.enumerated() {
            #expect(byte == data[i] ^ maskData.bytes[i % maskData.count])
        }
    }

    @Test
    func givenProcessor_whenPtrPos_thenIsExpected() {
        let sut = PacketProcessor(method: .xorptrpos)
        let data = prng.data(length: rndLength)
        let processed = sut.processPacket(data, direction: .inbound)
        print(data.toHex())
        print(processed.toHex())
        for (i, byte) in processed.enumerated() {
            #expect(byte == data[i] ^ UInt8((i + 1) & 0xff))
        }
    }

    @Test
    func givenProcessor_whenReverse_thenIsExpected() {
        let sut = PacketProcessor(method: .reverse)
        var data = prng.data(length: 10)
        var processed = sut.processPacket(data, direction: .inbound)
        print(data.toHex())
        print(processed.toHex())

        #expect(processed[0] == data[0])
        data.removeFirst()
        processed.removeFirst()
        print(data.toHex())
        print(processed.toHex())
        assert(data.count == 9)
        assert(processed.count == 9)
        #expect(processed == Data(data.reversed()))

//        // this crashes as if it returned pre-removeFirst() offsets, bug in Data?
//        for (i, byte) in processed.enumerated() {
//            XCTAssertEqual(byte, data[data.count - i - 1])
//        }
//
//        // this crashes for the same reason
//        for (i, byte) in processed.reversed().enumerated() {
//            XCTAssertEqual(byte, data[i])
//        }
    }

    //
    // original = "832ae7598dfa0378bc19"
    // ptrpos   = "8228e45d88fc0470b513"
    // reverse  = "8213b57004fc885de428"
    // ptrpos   = "8311b67401fa8f55ed22"
    // mask     = "e52680106098bc658b15"
    //
    @Test(arguments: [
        ("832ae7598dfa0378bc19", "e52680106098bc658b15", PacketProcessor.Direction.outbound),
        ("e52680106098bc658b15", "832ae7598dfa0378bc19", .inbound)
    ])
    func givenProcessor_whenObfuscate_thenIsExpected(input: String, output: String, direction: PacketProcessor.Direction) {
        let sut = PacketProcessor(method: .obfuscate(mask: mask))
        let data = Data(hex: input)
        let processed = sut.processPacket(data, direction: direction)
        let expected = Data(hex: output)

        print(data.toHex())
        print(processed.toHex())
        #expect(processed == expected)
    }

    // MARK: - Streams

    @Test
    func givenProcessor_whenSendSinglePacketStream_thenIsExpected() {
        let sut = PacketProcessor(method: nil)
        let packet = Data(hex: "1122334455")
        let expected = Data(hex: "00051122334455")
        let processed = sut.stream(fromPacket: packet)
        print(processed.toHex())
        print(expected.toHex())
        #expect(processed == expected)
    }

    @Test
    func givenProcessor_whenSendMultiplePacketsStream_thenIsExpected() {
        let sut = PacketProcessor(method: nil)
        let packets = [Data](repeating: Data(hex: "1122334455"), count: 3)
        let expected = Data(hex: "000511223344550005112233445500051122334455")
        let processed = sut.stream(fromPackets: packets)
        print(processed.toHex())
        print(expected.toHex())
        #expect(processed == expected)
    }

    @Test
    func givenProcessor_whenReceiveStream_thenIsExpected() {
        let sut = PacketProcessor(method: nil)
        let stream = Data(hex: "000511223344550005112233445500051122334455")
        let expected = [Data](repeating: Data(hex: "1122334455"), count: 3)
        var until = 0
        let processed = sut.packets(fromStream: stream, until: &until)
        print(processed.map { $0.toHex() })
        print(expected.map { $0.toHex() })
        #expect(processed == expected)
        #expect(until == stream.count)
    }

    @Test
    func givenProcessor_whenReceivePartialStream_thenIsExpected() {
        let sut = PacketProcessor(method: nil)
        let stream1 = Data(hex: "000511223344550005112233")
        let stream2 = Data(hex: "445500051122334455")
        let expected = [Data](repeating: Data(hex: "1122334455"), count: 3)

        var until = 0
        let processed1 = sut.packets(fromStream: stream1, until: &until)
        #expect(until == 7)

        let stream1Plus2 = stream1.subdata(offset: until, count: stream1.count - until) + stream2
        let processed2 = sut.packets(fromStream: stream1Plus2, until: &until)
        #expect(until == stream1Plus2.count)

        let processed = processed1 + processed2
        print(processed.map { $0.toHex() })
        print(expected.map { $0.toHex() })
        #expect(processed == expected)
    }

    @Test
    func givenStream_whenHandlePackets_thenIsReassembled() {
        var bytes: [UInt8] = []
        var until: Int = 0
        var packets: [Data]

        bytes.append(contentsOf: [0x00, 0x04])
        bytes.append(contentsOf: [0x10, 0x20, 0x30, 0x40])
        bytes.append(contentsOf: [0x00, 0x07])
        bytes.append(contentsOf: [0x10, 0x20, 0x30, 0x40, 0x50, 0x66, 0x77])
        bytes.append(contentsOf: [0x00, 0x01])
        bytes.append(contentsOf: [0xff])
        bytes.append(contentsOf: [0x00, 0x03])
        bytes.append(contentsOf: [0xaa])
        #expect(bytes.count == 21)

        packets = stream(from: bytes, until: &until)
        #expect(until == 18)
        #expect(packets.count == 3)

        bytes.append(contentsOf: [0xbb, 0xcc])
        packets = stream(from: bytes, until: &until)
        #expect(until == 23)
        #expect(packets.count == 4)

        bytes.append(contentsOf: [0x00, 0x05])
        packets = stream(from: bytes, until: &until)
        #expect(until == 23)
        #expect(packets.count == 4)

        bytes.append(contentsOf: [0x11, 0x22, 0x33, 0x44])
        packets = stream(from: bytes, until: &until)
        #expect(until == 23)
        #expect(packets.count == 4)

        bytes.append(contentsOf: [0x55])
        packets = stream(from: bytes, until: &until)
        #expect(until == 30)
        #expect(packets.count == 5)

        //

        bytes.removeSubrange(0..<until)
        #expect(bytes.count == 0)

        bytes.append(contentsOf: [0x00, 0x04])
        bytes.append(contentsOf: [0x10, 0x20])
        packets = stream(from: bytes, until: &until)
        #expect(until == 0)
        #expect(packets.count == 0)
        bytes.removeSubrange(0..<until)
        #expect(bytes.count == 4)

        bytes.append(contentsOf: [0x30, 0x40])
        bytes.append(contentsOf: [0x00, 0x07])
        bytes.append(contentsOf: [0x10, 0x20, 0x30, 0x40])
        packets = stream(from: bytes, until: &until)
        #expect(until == 6)
        #expect(packets.count == 1)
        bytes.removeSubrange(0..<until)
        #expect(bytes.count == 6)

        bytes.append(contentsOf: [0x50, 0x66, 0x77])
        bytes.append(contentsOf: [0x00, 0x01])
        bytes.append(contentsOf: [0xff])
        bytes.append(contentsOf: [0x00, 0x03])
        bytes.append(contentsOf: [0xaa])
        packets = stream(from: bytes, until: &until)
        #expect(until == 12)
        #expect(packets.count == 2)
        bytes.removeSubrange(0..<until)
        #expect(bytes.count == 3)

        bytes.append(contentsOf: [0xbb, 0xcc])
        packets = stream(from: bytes, until: &until)
        #expect(until == 5)
        #expect(packets.count == 1)
        bytes.removeSubrange(0..<until)
        #expect(bytes.count == 0)
    }

    // MARK: - Reversibility

    @Test
    func givenProcessor_whenMask_thenIsReversible() {
        let sut = PacketProcessor(method: .xormask(mask: mask))
        sut.assertReversible(prng.data(length: rndLength))
    }

    @Test
    func givenProcessor_whenPtrPos_thenIsReversible() {
        let sut = PacketProcessor(method: .xorptrpos)
        sut.assertReversible(prng.data(length: rndLength))
    }

    @Test
    func givenProcessor_whenReverse_thenIsReversible() {
        let sut = PacketProcessor(method: .reverse)
        sut.assertReversible(prng.data(length: rndLength))
    }

    @Test
    func givenProcessor_whenObfuscate_thenIsReversible() {
        let sut = PacketProcessor(method: .obfuscate(mask: mask))
        sut.assertReversible(prng.data(length: rndLength))
    }

    @Test
    func givenStream_whenProcess_thenIsReversible() {
        let sut = prng.data(length: 10000)
        PacketProcessor(method: nil)
            .assertReversibleStream(sut)
        PacketProcessor(method: .xormask(mask: mask))
            .assertReversibleStream(sut)
        PacketProcessor(method: .xorptrpos)
            .assertReversibleStream(sut)
        PacketProcessor(method: .reverse)
            .assertReversibleStream(sut)
        PacketProcessor(method: .obfuscate(mask: mask))
            .assertReversibleStream(sut)
    }
}

// MARK: - Helpers

private extension PacketProcessor {
    func assertReversible(_ data: Data) {
        let xorred = processPacket(data, direction: .outbound)
        #expect(processPacket(xorred, direction: .inbound) == data)
    }

    func assertReversibleStream(_ data: Data) {
        var until = 0
        let outStream = stream(fromPacket: data)
        let inStream = packets(fromStream: outStream, until: &until)
        let originalData = Data(inStream.joined())
        #expect(data.toHex() == originalData.toHex())
    }
}

private extension PacketProcessorTests {
    func stream(from bytes: [UInt8], until: inout Int) -> [Data] {
        PacketProcessor(method: nil)
            .packets(fromStream: Data(bytes), until: &until)
    }
}
