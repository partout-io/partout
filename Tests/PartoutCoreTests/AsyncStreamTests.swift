// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct AsyncStreamTests {
    @Test
    func givenPassthrough_whenEmit_thenMatches() async throws {
        let sut = PassthroughStream<UniqueID, Int>()
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

    @Test
    func givenCurrentValue_whenEmit_thenMatches() async throws {
        let sut = CurrentValueStream<UniqueID, Int>(100)
        let sequence = [5, 7, 67]
        let expected = [100] + sequence
        let stream = sut.subscribe()
        Task {
            for num in sequence {
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

#if canImport(Combine)
import Combine
import PartoutCore

extension AsyncStreamTests {
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
