// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutWireGuard
import Testing

struct ParseErrorTests {
    @Test
    func givenParseError_whenMap_thenReturnsAsReason() throws {
        let sut = WireGuardParseError.noInterface
        let mapped = sut.asPartoutError
        #expect(mapped.reason is WireGuardParseError)
        let reason = try #require(mapped.reason as? WireGuardParseError)
        switch reason {
        case .noInterface:
            break
        default:
            #expect(Bool(false), "Mapped to different error: \(reason)")
        }
    }
}
