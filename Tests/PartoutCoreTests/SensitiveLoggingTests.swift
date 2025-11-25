// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
internal import _PartoutCore_C
import Testing

struct SensitiveLoggingTests {
    @Test
    func givenNoLogRawBytes_whenAsSensitive_thenOmitsSensitiveData() {
        assert(!PartoutLogger.default.logsRawBytes)
        let sut = Data(hex: "aabbccddeeff")
        #expect(sut.asSensitiveBytes(.global) == sut.debugDescription(withSensitiveData: false))
    }

    @Test
    func givenNoLogAddresses_whenAsSensitive_thenOmitsSensitiveData() throws {
        assert(!PartoutLogger.default.logsAddresses)
        let sut = try #require(Address(rawValue: "1.1.1.1"))
        #expect(sut.asSensitiveAddress(.global) == sut.debugDescription(withSensitiveData: false))
    }

    @Test
    func givenData_whenAsSensitive_thenOmitsSensitiveData() throws {
        let sut = Data(hex: "12345678abcdef")
        #expect(sut.debugDescription(withSensitiveData: true) == "[7 bytes, 12345678abcdef]")
        #expect(sut.debugDescription(withSensitiveData: false) == "[7 bytes]")
    }

    @Test
    func givenString_whenAsSensitive_thenOmitsSensitiveData() throws {
        let sut = "some string"
        #expect(sut.debugDescription(withSensitiveData: true) == sut)
        #expect(sut.debugDescription(withSensitiveData: false) == PartoutLogger.redactedValue)
    }
}
