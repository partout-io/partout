// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct DataManipulationTests {
    @Test
    func givenHexDigit_whenToNibble_thenIsExpected() {
        var expected: UInt8

        expected = 0
        for sut in "0123456789ABCDEF" {
            #expect(sut.unicodeScalars.map(\.hexNibble) == [expected])
            expected += 1
        }
        #expect(expected == 16)

        expected = 0
        for sut in "0123456789abcdef" {
            #expect(sut.unicodeScalars.map(\.hexNibble) == [expected])
            expected += 1
        }
        #expect(expected == 16)
    }

    @Test
    func givenData_whenToHex_thenIsExpected() {
        let sut = Data([0x11, 0x22, 0x33, 0x44])
        let hex = "11223344"
        #expect(sut.toHex() == hex)
        #expect(Data(hex: hex) == sut)
    }

    @Test
    func givenData_whenZero_thenIsZeroedOut() {
        var sut = Data(hex: "112233445566aabbccdd")
        sut.zero(from: 4, to: 6)
        #expect(sut == Data(hex: "112233440000aabbccdd"))
        sut.zero()
        #expect(sut == Data(hex: "00000000000000000000"))
    }

    @Test
    func givenData_whenAppendUInt_thenIsAppended() {
        var sut = Data(hex: "112233445566aabbccdd")
        sut.append(UInt16(0x1234))
        #expect(sut == Data(hex: "112233445566aabbccdd3412"))
        sut.append(UInt32(0x12345678))
        #expect(sut == Data(hex: "112233445566aabbccdd341278563412"))
        sut.append(UInt64(0x1234567812345678))
        #expect(sut == Data(hex: "112233445566aabbccdd3412785634127856341278563412"))
    }

    @Test
    func givenData_whenParseUInt_thenIsExpected() {
        let sut = Data(hex: "22ffaabb5566")
        #expect(sut.UInt16Value(from: 3) == 0x55bb)
        #expect(sut.UInt32Value(from: 2) == 0x6655bbaa)
        #expect(sut.UInt16Value(from: 4) == 0x6655)
        #expect(sut.UInt32Value(from: 0) == 0xbbaaff22)
    }

    @Test
    func givenData_whenAppendData_thenIsExpected() {
        var sut = Data()
        sut.append(Data(hex: "11223344"))
        sut.append(Data(hex: "1122"))
        sut.append(Data(hex: "1122334455"))
        sut.append(Data(hex: "11223344556677"))
        sut.append(Data(hex: "112233"))
        #expect(sut == Data(hex: "112233441122112233445511223344556677112233"))
    }

    @Test
    func givenData_whenSubdata_thenIsExpected() {
        let sut = Data(hex: "112233441122112233445511223344556677112233")
        #expect(sut.subdata(offset: 4, count: 6) == Data(hex: "112211223344"))
    }

    @Test
    func givenArrayOfData_whenAppendData_thenFlatCountSumsUp() {
        var sut: [Data] = []
        sut.append(Data(hex: "11223344"))
        sut.append(Data(hex: "1122"))
        sut.append(Data(hex: "1122334455"))
        sut.append(Data(hex: "11223344556677"))
        sut.append(Data(hex: "112233"))
        #expect(sut.flatCount == 21)
    }

    @Test
    func givenData_whenAppendNullTerminatedString_thenIsExpected() throws {
        let prefix = Data(hex: "bbddeeff")
        let suffix = Data(hex: "662288")

        let string = "hello"
        var expected = Data()
        expected.append(prefix)
        expected.append(try #require(string.data(using: .utf8)))
        expected.append(UInt8(0))
        expected.append(suffix)

        var sut = Data()
        sut.append(Data(hex: "bbddeeff"))
        sut.append(nullTerminatedString: "hello")
        sut.append(Data(hex: "662288"))
        #expect(sut == expected)
        #expect(sut.nullTerminatedString(from: 4) == string)
        #expect(sut.nullTerminatedString(from: 0) != string)
        #expect(sut.nullTerminatedString(from: 12) != string)
        #expect(sut.nullTerminatedString(from: 12) == nil)
    }
}
