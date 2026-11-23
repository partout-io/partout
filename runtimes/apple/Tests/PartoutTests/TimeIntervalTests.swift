// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Testing

struct TimeIntervalTests {
    @Test
    func givenInterval_whenConvertToTimeString_thenIsExpected() {
        #expect(0.0.asTimeString == "0s")
        #expect(10.0.asTimeString == "10s")
        #expect(60.0.asTimeString == "1m")
        #expect(120.0.asTimeString == "2m")
        #expect(121.0.asTimeString == "2m1s")
        #expect(3600.0.asTimeString == "1h")
        #expect(3601.0.asTimeString == "1h1s")
        #expect(3660.0.asTimeString == "1h1m")
        #expect(3661.0.asTimeString == "1h1m1s")
    }
}
