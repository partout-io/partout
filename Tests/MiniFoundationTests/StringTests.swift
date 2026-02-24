// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
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

#if !canImport(MiniFoundationNative)
    @Test(arguments: [
        ("file://nonexisting.txt", true),
        ("https://nonexisting/path", false)
    ])
    func urlContents(string: String, isFile: Bool) throws {
        let url = try #require(Compat.URL(string: string))
        do {
            _ = try String(contentsOf: url, encoding: .utf8)
            #expect(isFile)
        } catch let mfError as MiniFoundationError {
            switch mfError {
            case .notFileURL: #expect(!isFile) // Non-file URL stops at this error
            default: #expect(isFile) // File URL stops at I/O (non-existing file)
            }
        }
    }
#endif
}
