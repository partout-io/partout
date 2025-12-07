// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation
import Testing

struct DataTests {
    @Test(arguments: [
        ("x3XuJXi8SfYKHvHDZaAem6YrtbATHN2Zeo5aQrpdiQ==", "c775ee2578bc49f60a1ef1c365a01e9ba62bb5b0131cdd997a8e5a42ba5d89"),
        ("NYA6oE6qG4le", "35803aa04eaa1b895e"),
        ("JD6EqILKo7QlkFh6FhBxWjDV3qkk3lZRZQRi1Q==", "243e84a882caa3b42590587a1610715a30d5dea924de5651650462d5"),
        ("ZKDdnY0R3yl3EoluceTl9sz1ojBvz4CnT8nlXBHqAls=", "64a0dd9d8d11df297712896e71e4e5f6ccf5a2306fcf80a74fc9e55c11ea025b"),
        ("KrO6ocLV+CPdObIkyo7gViTD68qS", "2ab3baa1c2d5f823dd39b224ca8ee05624c3ebca92"),
        ("1mW9sIP5ag7S9VeG0pVIiQ==", "d665bdb083f96a0ed2f55786d2954889"),
        ("tEtZBQhspDl2XpgNN6iYizWrNgnGsGC8cTM=", "b44b5905086ca439765e980d37a8988b35ab3609c6b060bc7133"),
        ("uu89E/L106JxFZ9GGWUl", "baef3d13f2f5d3a271159f46196525"),
        ("uRNmuirO3TLOZa1/VsPZ90sG+5klrHDRqJkLoQ==", "b91366ba2acedd32ce65ad7f56c3d9f74b06fb9925ac70d1a8990ba1"),
        ("8I0+vo/568hc4Q0oty+D", "f08d3ebe8ff9ebc85ce10d28b72f83")
    ])
    func base64(string: String, hex: String) throws {
        let base64Data = try #require(Data(base64Encoded: string))
        #expect(base64Data.base64EncodedString() == string)
        let hexData = try #require(hex.hexData())
        #expect(base64Data == hexData)
    }
}
