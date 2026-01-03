// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation
import Testing

struct CharacterSetTests {
    @Test
    func containment() {
        #expect(!CharacterSet(charactersIn: "abcd").contains("e"))
        #expect(CharacterSet(charactersIn: "abcd").contains("d"))
        #expect(!CharacterSet(charactersIn: "abcd").contains("C"))
        #expect(!CharacterSet.whitespaces.contains("C"))
        #expect(CharacterSet.whitespaces.contains(" "))
        #expect(CharacterSet.whitespacesAndNewlines.contains("\n"))
        #expect(!CharacterSet.newlines.contains("\t"))
        #expect(CharacterSet.newlines.contains("\n"))
    }

    @Test
    func inversion() {
        #expect(!CharacterSet.newlines.inverted.contains("\n"))
        #expect(CharacterSet.newlines.inverted.inverted.contains("\n"))
    }

    @Test
    func union() {
        let digitsNewLines: CharacterSet = .decimalDigits.union(.newlines)
        #expect(digitsNewLines.contains("\n"))
        #expect(!digitsNewLines.contains("B"))
        #expect(digitsNewLines.contains("4"))
    }
}
