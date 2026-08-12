// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct AsyncStreamTests {
    @Test
    func givenPassthrough_whenEmit_thenMatches() async throws {
        let sut = PassthroughStream<Int>()
        let expected = [5, 7, 67]
        let stream = sut.subscribe()
        Task {
            for num in expected {
                sut.send(num)
                try await Task.sleep(for: .milliseconds(100))
            }
            sut.finish()
        }
        var i = 0
        for try await num in stream {
            print("Number: \(num)")
            #expect(i < expected.count, "Emitted more values than sequence length")
            #expect(num == expected[i])
            i += 1
        }
    }
}
