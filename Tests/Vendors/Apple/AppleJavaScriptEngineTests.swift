// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutVendorsApple
import Foundation
import Testing

struct AppleJavaScriptEngineTests {
    @Test
    func givenEngine_whenInject_thenReturns() async throws {
        let sut = AppleJavaScriptEngine(.global)
        sut.inject("triple", object: {
            3 * $0
        } as @convention(block) (Int) -> Int)
        let result = try await sut.execute("""
triple(40);
""", after: nil, returning: Int.self)
        #expect(result == 120)
    }
}
