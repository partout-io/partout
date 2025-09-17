// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if OPENVPN_DEPRECATED_LZO

import Foundation
@testable import PartoutOpenVPN
import Testing

final class LZOTests {
    @Test
    func givenData_whenCompress_thenIsDecompressed() throws {
        let sut = LZO()
        let src = Data([UInt8](repeating: 0x43, count: 100))
        let dst = try sut.compressed(src)
        let dstDecompressed = try sut.decompressed(dst)
        #expect(src == dstDecompressed)
    }
}

#endif
