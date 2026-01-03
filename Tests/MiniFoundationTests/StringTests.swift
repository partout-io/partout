// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation
import Testing

struct StringTests {
    @Test(arguments: [
        ("%x", 7, "7"),
        ("%x", 63, "3f"),
        ("%X", 63, "3F"),
        ("%02x", 57, "39"),
        ("%02x", 7, "07")
    ])
    func hexFormat(format: String, arg: Int, string: String) {
        #expect(String(format: format, arg) == string)
    }
}
