// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct ExpectationTests {
    @Test
    func fulfillmentThrowsAtTimeout() async {
        let expectation = Expectation()

        await #expect(throws: Error.self) {
            try await expectation.fulfillment(timeout: 10)
        }
    }
}
