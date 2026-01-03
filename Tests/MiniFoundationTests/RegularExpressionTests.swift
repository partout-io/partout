// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation
import Testing

struct RegularExpressionTests {
    @Test(arguments: [
        // ("", "", [""]),
        ("a", "a", ["a"]),
        ("a", "aaa", ["a", "a", "a"]),
        ("aa", "aaaa", ["aa", "aa"]),
        ("\\d+", "abc123def456", ["123", "456"]),
        ("\\w+", "hello world", ["hello", "world"]),
        ("[A-Za-z]+", "test123foo", ["test", "foo"]),
        ("\\s+", "a  b   c", ["  ", "   "]),
        ("foo", "foofoo", ["foo", "foo"]),
        ("(foo)", "foo bar foo", ["foo", "foo"]),
        ("[A-Z][a-z]+", "JohnDoe", ["John", "Doe"]),
        ("\\b\\w{3}\\b", "one two three four", ["one", "two"]),
        (".", "abc", ["a", "b", "c"]),
        ("\\d*", "ab", ["", "", ""]) // special: zero-length matches
    ])
    func matches(pattern: String, subject: String, matches: [String]) {
        var i = 0
        RegularExpression(pattern).enumerateMatches(in: subject) { match in
            assert(i < matches.count)
            #expect(match == matches[i])
            i += 1
        }
    }
}
