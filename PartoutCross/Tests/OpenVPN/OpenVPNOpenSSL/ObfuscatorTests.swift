//
//  ObfuscatorTests.swift
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

@testable internal import _PartoutOpenVPNOpenSSL_Cross
import PartoutCore
import XCTest

final class ObfuscatorTests: XCTestCase {
    private let prng = SimplePRNG()

    private let rndLength = 237

    private let mask = SecureData("f76dab30")!

    func test_givenProcessor_whenMask_thenIsExpected() {
        let sut = Obfuscator(method: .xormask(mask: mask))
        let data = prng.data(length: rndLength)
        let maskData = mask.czData
        let processed = sut.processPacket(data, direction: .inbound)
        print(data.toHex())
        print(processed.toHex())
        for (i, byte) in processed.enumerated() {
            XCTAssertEqual(byte, data[i] ^ maskData.bytes[i % maskData.length])
        }
    }

    func test_givenProcessor_whenPtrPos_thenIsExpected() {
        let sut = Obfuscator(method: .xorptrpos)
        let data = prng.data(length: rndLength)
        let processed = sut.processPacket(data, direction: .inbound)
        print(data.toHex())
        print(processed.toHex())
        for (i, byte) in processed.enumerated() {
            XCTAssertEqual(byte, data[i] ^ UInt8((i + 1) & 0xff))
        }
    }

    func test_givenProcessor_whenReverse_thenIsExpected() {
        let sut = Obfuscator(method: .reverse)
        var data = prng.data(length: 10)
        var processed = sut.processPacket(data, direction: .inbound)
        print(data.toHex())
        print(processed.toHex())

        XCTAssertEqual(processed[0], data[0])
        data.removeFirst()
        processed.removeFirst()
        print(data.toHex())
        print(processed.toHex())
        assert(data.count == 9)
        assert(processed.count == 9)
        XCTAssertEqual(processed, Data(data.reversed()))

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

    func test_givenProcessor_whenObfuscateOutbound_thenIsExpected() {
        let sut = Obfuscator(method: .obfuscate(mask: mask))
        let data = Data(hex: "832ae7598dfa0378bc19")
        let processed = sut.processPacket(data, direction: .outbound)
        let expected = Data(hex: "e52680106098bc658b15")

        // original = "832ae7598dfa0378bc19"
        // ptrpos   = "8228e45d88fc0470b513"
        // reverse  = "8213b57004fc885de428"
        // ptrpos   = "8311b67401fa8f55ed22"
        // mask     = "e52680106098bc658b15"

        print(data.toHex())
        print(processed.toHex())
        XCTAssertEqual(processed, expected)
    }

    func test_givenProcessor_whenObfuscateInbound_thenIsExpected() {
        let sut = Obfuscator(method: .obfuscate(mask: mask))
        let data = Data(hex: "e52680106098bc658b15")
        let processed = sut.processPacket(data, direction: .inbound)
        let expected = Data(hex: "832ae7598dfa0378bc19")

        print(data.toHex())
        print(processed.toHex())
        XCTAssertEqual(processed, expected)
    }

    func test_givenProcessor_whenMask_thenIsReversible() {
        let sut = Obfuscator(method: .xormask(mask: mask))
        sut.assertReversible(prng.data(length: rndLength))
    }

    func test_givenProcessor_whenPtrPos_thenIsReversible() {
        let sut = Obfuscator(method: .xorptrpos)
        sut.assertReversible(prng.data(length: rndLength))
    }

    func test_givenProcessor_whenReverse_thenIsReversible() {
        let sut = Obfuscator(method: .reverse)
        sut.assertReversible(prng.data(length: rndLength))
    }

    func test_givenProcessor_whenObfuscate_thenIsReversible() {
        let sut = Obfuscator(method: .obfuscate(mask: mask))
        sut.assertReversible(prng.data(length: rndLength))
    }

    // FIXME: ##, test XOR in PacketStream
//    func test_givenPacketStream_whenXORthenIsReversible() {
//        let sut = prng.data(length: 10000)
//        PacketStream.assertReversible(sut, method: .none)
//        PacketStream.assertReversible(sut, method: .mask, mask: mask)
//        PacketStream.assertReversible(sut, method: .ptrPos)
//        PacketStream.assertReversible(sut, method: .reverse)
//        PacketStream.assertReversible(sut, method: .obfuscate, mask: mask)
//    }
}

// MARK: - Helpers

private extension Obfuscator {
    func assertReversible(_ data: Data) {
        let xorred = processPacket(data, direction: .outbound)
        XCTAssertEqual(processPacket(xorred, direction: .inbound), data)
    }
}

// FIXME: ##, test XOR in PacketStream
//private extension PacketStream {
//    static func assertReversible(_ data: Data, method: ObfuscationMethodNative, mask: SecureData? = nil) {
//        var until = 0
//        let outStream = PacketStream.outboundStream(fromPacket: data, xorMethod: method, xorMask: mask?.zData)
//        let inStream = PacketStream.packets(fromInboundStream: outStream, until: &until, xorMethod: method, xorMask: mask?.zData)
//        let originalData = Data(inStream.joined())
//        XCTAssertEqual(data.toHex(), originalData.toHex())
//    }
//}
