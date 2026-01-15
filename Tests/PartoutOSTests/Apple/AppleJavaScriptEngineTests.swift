// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import PartoutOS
import Testing

struct AppleJavaScriptEngineTests {
    @Test
    func givenEngine_whenInject_thenReturns() async throws {
        let sut = AppleJavaScriptEngine()
        sut.inject("triple", object: {
            3 * $0
        } as @convention(block) (Int) -> Int)
        let result = try await sut.execute("""
triple(40);
""", after: nil, returning: Int.self)
        #expect(result == 120)
    }
}
