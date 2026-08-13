// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutLegacyCore
import Testing

#if canImport(Combine)
import Combine
import PartoutLegacyCore

struct AsyncStreamTests {
    @Test
    func givenKVO_whenIterateStream_thenIsExpected() async throws {
        let sut = KVOObject()
        let stream = stream(for: \.value, of: sut, filter: { _ in true })
        let sequence = [1, 2, 30, 40, 100]
        let expected = [0] + sequence // initial value
        Task {
            for num in sequence {
                sut.value = num
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        var i = 0
        for await num in stream {
            #expect(num == expected[i])
            i += 1
            if i == expected.count {
                return
            }
        }
    }
}

private final class KVOObject: NSObject {
    @objc dynamic var value: Int = 0

    override init() {
    }
}
#endif
