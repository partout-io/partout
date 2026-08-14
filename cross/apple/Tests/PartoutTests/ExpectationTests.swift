// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Testing

struct ExpectationTests {
    @Test
    func fulfillmentThrowsAtTimeout() async {
        let expectation = Expectation()

        do {
            try await expectation.fulfillment(timeout: 10)
            Issue.record("Expected fulfillment to time out")
        } catch is Expectation.TimeoutError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
