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

    @Test(arguments: [
        ("foo.txt", "foo\nbar\nbaz\n")
    ])
    func fileContents(filename: String, expectedContents: String) throws {
        let url = try #require(Bundle.module.url(forResource: filename, withExtension: nil))
        let foundContents = try String(contentsOf: url, encoding: .utf8)
        print(foundContents)
        #expect(foundContents == expectedContents)
    }
}
