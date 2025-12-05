// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation

print(MiniFoundation.operatingSystemVersion())
let list = try FileManager.default.contentsOfDirectory(atPath: ".")
print(list)
// let data = try JSONEncoder().encode(url)
// let json = String(data: data, encoding: .utf8)
// print(json!)
guard let url = URL(string: "https://abi.com/one///two?foobar") else {
    fatalError()
}
print("URL: \(url)")
print("Path: \(url.path)")
print("Last path component: \(url.lastPathComponent)")
print(FileManager.default.makeTemporaryPath(filename: "hello.world"))
