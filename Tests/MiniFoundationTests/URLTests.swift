// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation
import Testing

struct URLTests {
    @Test(arguments: [
        ("gopher://[2001::4]/dns", "gopher", "2001::4", nil as Int?, "/dns", "dns", nil as String?, nil as String?),
        ("https://google.com:13000/path/to/somewhere.txt?query#fragment", "https", "google.com", 13000, "/path/to/somewhere.txt", "somewhere.txt", "query", "fragment"),
        ("gopher://1.2.3.4/dns", "gopher", "1.2.3.4", nil, "/dns", "dns", nil, nil),
        ("gopher://[2001::4]/dns", "gopher", "2001::4", nil, "/dns", "dns", nil, nil),
        ("http://[2001:4860:0:2001::68]/foo/bar?a=123", "http", "2001:4860:0:2001::68", nil, "/foo/bar", "bar", "a=123", nil),
        ("file:///home/john/file.txt", "file", nil, nil, "/home/john/file.txt", "file.txt", nil, nil),
        ("file:///home/john%20wick/file.txt", "file", nil, nil, "/home/john wick/file.txt", "file.txt", nil, nil),
        // Foundation only trims the last slash, minif trims them all
//        ("file:///home/john/file.txt///", "file", nil, nil, "/home/john/file.txt", "file.txt", nil, nil)
    ])
    func parsing(
        string: String,
        scheme: String,
        host: String?,
        port: Int?,
        path: String,
        lastPath: String,
        query: String?,
        fragment: String?
    ) async throws {
        let url = try #require(URL(string: string))
        #expect(url.absoluteString == string)
        #expect(url.scheme == scheme)
        #expect(url.host == host)
        #expect(url.port == port)
        #expect(url.path == path)
        #expect(url.lastPathComponent == lastPath)
        #expect(url.query == query)
        #expect(url.fragment == fragment)
    }

//    @Test
//    func building() throws {
//        var url = try #require(URL(string: "https://abi.com?foobar"))
//        url = url.miniAppending(component: "jesuschrist")
//        #expect(url.absoluteString == "https://abi.com/jesuschrist?foobar")
//        url = url.miniAppending(pathExtension: "json")
//        #expect(url.absoluteString == "https://abi.com/jesuschrist.json?foobar")
//        url = url.miniAppending(component: "/")
//        url = url.miniAppending(pathExtension: "hi")
//        #expect(url.absoluteString == "https://abi.com/jesuschrist.json/.hi/?foobar")
//    }
}
