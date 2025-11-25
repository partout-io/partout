// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(Combine)

@preconcurrency import Combine
import PartoutCore
import Testing

struct SubjectTests {

    @Test
    func givenPassthrough_whenSink_thenMatches() async throws {
        let sut = PassthroughSubject<Int, Error>()
        let expected = [5, 7, 67]
        var i = 0
        var isDone = false
        var subscriptions: Set<AnyCancellable> = []

        sut
            .sink { _ in
                isDone = true
            } receiveValue: { num in
                print("Number: \(num)")
                guard i < expected.count else {
                    #expect(Bool(false), "Emitted more values than sequence length")
                    return
                }
                #expect(num == expected[i])
                i += 1
            }
            .store(in: &subscriptions)

        for num in expected {
            sut.send(num)
            try await Task.sleep(for: .milliseconds(100))
        }
        sut.send(completion: .finished)
        while !isDone {} // spinlock
    }

    @Test
    func givenPassthrough_whenStream_thenMatches() async throws {
        let sut = PassthroughSubject<Int, Error>()
        let expected = [5, 7, 67]
        let stream = sut.stream()
        Task {
            for num in expected {
                sut.send(num)
                try await Task.sleep(for: .milliseconds(100))
            }
            sut.send(completion: .finished)
        }
        var i = 0
        for try await num in stream {
            print("Number: \(num)")
            guard i < expected.count else {
                #expect(Bool(false), "Emitted more values than sequence length")
                return
            }
            #expect(num == expected[i])
            i += 1
        }
    }

    @Test
    func givenCurrentValue_whenSink_thenMatches() async throws {
        let sut = CurrentValueSubject<Int, Error>(100)
        let sequence = [5, 7, 67]
        let expected = [100] + sequence
        var i = 0
        var isDone = false
        var subscriptions: Set<AnyCancellable> = []

        sut
            .sink { _ in
                isDone = true
            } receiveValue: { num in
                print("Number: \(num)")
                guard i < expected.count else {
                    #expect(Bool(false), "Emitted more values than sequence length")
                    return
                }
                #expect(num == expected[i])
                i += 1
            }
            .store(in: &subscriptions)

        for num in sequence {
            sut.send(num)
            try await Task.sleep(for: .milliseconds(100))
        }
        sut.send(completion: .finished)
        while !isDone {} // spinlock
    }

    @Test
    func givenCurrentValue_whenStream_thenMatches() async throws {
        let sut = CurrentValueSubject<Int, Error>(100)
        let sequence = [5, 7, 67]
        let expected = [100] + sequence
        let stream = sut.stream()
        Task {
            for num in sequence {
                sut.send(num)
                try await Task.sleep(for: .milliseconds(100))
            }
            sut.send(completion: .finished)
        }
        var i = 0
        for try await num in stream {
            print("Number: \(num)")
            guard i < expected.count else {
                #expect(Bool(false), "Emitted more values than sequence length")
                return
            }
            #expect(num == expected[i])
            i += 1
        }
    }
}

#endif
