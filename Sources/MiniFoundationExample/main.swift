// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation

print(MiniFoundation.operatingSystemVersion())
let list = try FileManager.default.miniContentsOfDirectory(at: URL(fileURLWithPath: "."))
print(list)
// let data = try JSONEncoder().encode(url)
// let json = String(data: data, encoding: .utf8)
// print(json!)
guard let url = URL(string: "https://abi.com/one///two?foobar") else {
    fatalError()
}
print("URL: \(url)")
print("Path: \(url.filePath())")
print("Last path component: \(url.lastPathComponent)")
print(FileManager.default.makeTemporaryURL(filename: "hello.world"))
