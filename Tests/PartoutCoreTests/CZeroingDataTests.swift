// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import Testing

struct CZeroingDataTests {
    @Test
    func givenInput_whenInit_thenReturnsExpected() {
        #expect(CZeroingData(count: 123).count == 123)
        #expect(CZeroingData(bytes: [0x11, 0x22, 0x33, 0x44, 0x55], count: 3).count == 3)
        #expect(CZeroingData(uInt8: UInt8(78)).count == 1)
        #expect(CZeroingData(uInt16: UInt16(4756)).count == 2)
        #expect(CZeroingData(data: Data(count: 12)).count == 12)
        #expect(CZeroingData(data: Data(count: 12), offset: 3, count: 7).count == 7)
        #expect(CZeroingData(string: "hello", nullTerminated: false).count == 5)
        #expect(CZeroingData(string: "hello", nullTerminated: true).count == 6)
    }

    @Test
    func givenData_whenOffset_thenReturnsExpected() {
        let sut = CZeroingData(string: "Hello", nullTerminated: true)
        #expect(sut.networkUInt16Value(fromOffset: 3) == 0x6c6f)
        #expect(sut.nullTerminatedString(fromOffset: 0) == "Hello")
        #expect(sut.withOffset(3, count: 2) == CZeroingData(string: "lo", nullTerminated: false))
    }

    @Test
    func givenData_whenAppend_thenIsAppended() {
        let sut = CZeroingData(string: "this_data", nullTerminated: false)
        let other = CZeroingData(string: "that_data", nullTerminated: false)

        let merged = sut.copy()
        merged.append(other)
        #expect(merged == CZeroingData(string: "this_datathat_data", nullTerminated: false))
        #expect(merged == sut.appending(other))
    }

    @Test
    func givenData_whenTruncate_thenIsTruncated() {
        let data = Data(hex: "438ac4729847fb3975345983")
        let sut = CZeroingData(data: data)

        sut.resize(toSize: 5)
        #expect(sut.count == 5)
        #expect(sut.toData() == data.subdata(in: 0..<5))
    }

    @Test
    func givenData_whenRemove_thenIsRemoved() {
        let data = Data(hex: "438ac4729847fb3975345983")
        let sut = CZeroingData(data: data)

        sut.remove(untilOffset: 5)
        #expect(sut.count == data.count - 5)
        #expect(sut.toData() == data.subdata(in: 5..<data.count))
    }

    @Test
    func givenData_whenZero_thenIsZeroedOut() {
        let data = Data(hex: "438ac4729847fb3975345983")
        let sut = CZeroingData(data: data)

        sut.zero()
        #expect(sut.count == data.count)
        #expect(sut.toData() == Data(repeating: 0, count: data.count))
    }

    @Test
    func givenData_whenCompareEqual_thenIsEqual() {
        let data = Data(hex: "438ac4729847fb3975345983")
        let sut = CZeroingData(data: data)
        let other = CZeroingData(data: data)

        #expect(sut == other)
        #expect(sut == sut.copy())
        #expect(other == other.copy())
        #expect(sut.copy() == other.copy())

        sut.append(CZeroingData(count: 1))
        #expect(sut != other)
        other.append(CZeroingData(count: 1))
        #expect(sut == other)
    }

    @Test
    func givenData_whenManipulate_thenDataIsExpected() {
        let z1 = CZeroingData(count: 0)
        z1.append(CZeroingData(data: Data(hex: "12345678")))
        z1.append(CZeroingData(data: Data(hex: "abcdef")))
        let z2 = z1.withOffset(2, count: 3) // 5678ab
        let z3 = z2.appending(CZeroingData(data: Data(hex: "aaddcc"))) // 5678abaaddcc

        #expect(z1.toData() == Data(hex: "12345678abcdef"))
        #expect(z2.toData() == Data(hex: "5678ab"))
        #expect(z3.toData() == Data(hex: "5678abaaddcc"))
    }
}
