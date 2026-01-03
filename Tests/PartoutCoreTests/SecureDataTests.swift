// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct SecureDataTests {
    @Test
    func givenData_whenEncode_thenDecodes() throws {
        let sut = SecureData("123456")
        let encoder = JSONEncoder()
        let data = try encoder.encode(sut)
        let expected = try JSONDecoder().decode(SecureData.self, from: data)
        #expect(expected == sut)
    }
}
