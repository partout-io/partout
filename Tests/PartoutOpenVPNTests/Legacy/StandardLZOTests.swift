// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutOpenVPN_ObjC
import XCTest

final class StandardLZOTests: XCTestCase {
    func test_givenData_whenCompress_thenIsDecompressed() throws {
        let sut = StandardLZO()
        let src = Data([UInt8](repeating: 6, count: 100))
        let dst = try sut.compressedData(with: src)
        let dstDecompressed = try sut.decompressedData(with: dst)
        XCTAssertEqual(src, dstDecompressed)
    }
}
