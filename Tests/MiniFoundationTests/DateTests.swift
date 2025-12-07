// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation
import Testing

struct DateTests {
    @Test
    func intervals() async throws {
        #expect(Date(timeIntervalSince1970: 0).timeIntervalSince1970 == 0)
        #expect(Date(timeIntervalSince1970: 10).timeIntervalSince1970 == 10)
        #expect(Date(timeIntervalSince1970: 0).addingTimeInterval(100).timeIntervalSince1970 == 100)
        #expect(Date(timeIntervalSince1970: 1000) == Date(timeIntervalSince1970: 1000))
        #expect(Date(timeIntervalSince1970: 1000) < Date(timeIntervalSince1970: 2000))

        let now = Date()
        print(now.timeIntervalSinceNow)
        try await Task.sleep(for: .seconds(1))
        print(-now.timeIntervalSinceNow)
    }
}
