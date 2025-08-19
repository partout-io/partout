// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutPortable
import Testing

struct CZeroingDataExtensionsTests {
    @Test
    func givenZeroingData_whenAsSensitive_thenOmitsSensitiveData() throws {
        let sut = CZX("12345678abcdef")
        #expect(sut.debugDescription(withSensitiveData: true) == "[7 bytes, 12345678abcdef]")
        #expect(sut.debugDescription(withSensitiveData: false) == "[7 bytes]")
    }
}
