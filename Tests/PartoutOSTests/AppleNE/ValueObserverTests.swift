// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutOS
import Testing

struct ValueObserverTests {
    @Test
    func givenSubject_whenValueIsExpected_thenSucceeds() async throws {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        let (waitTask, didStartWaiting) = startWait(sut) { newValue in
            newValue == 30
        }
        try await didStartWaiting.fulfillment(timeout: 1000)

        subject.value = 10
        subject.value = 20
        subject.value = 30

        try await waitTask.value
    }

    @Test
    func givenSubject_whenValueIsUndesired_thenFails() async throws {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        let (waitTask, didStartWaiting) = startWait(sut) { newValue in
            switch newValue {
            case 20:
                throw SomeError()

            default:
                return false
            }
        }
        try await didStartWaiting.fulfillment(timeout: 1000)

        subject.value = 10
        subject.value = 20

        do {
            try await waitTask.value
            #expect(Bool(false), "Undesired value should fail")
        } catch {
            #expect(type(of: error) == SomeError.self)
        }
    }

    @Test
    func givenSubject_whenValueIsDelayed_thenFailsWithTimeout() async {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        do {
            try await sut.waitForValue(on: \.value, timeout: 200) { _ in
                false
            }
            #expect(Bool(false), "Should time out")
        } catch let error as PartoutError {
            #expect(error.code == .timeout)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test
    func givenObserverIsReused_whenPreviousTimeoutExpires_thenDoesNotAffectNextWait() async throws {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        let previousTimeout = 500
        let (firstWaitTask, didStartFirstWait) = startWait(sut, timeout: previousTimeout) {
            $0 == 10
        }
        try await didStartFirstWait.fulfillment(timeout: 1000)
        subject.value = 10
        try await firstWaitTask.value

        let (secondWaitTask, didStartSecondWait) = startWait(sut, timeout: 1500) {
            $0 == 20
        }
        try await didStartSecondWait.fulfillment(timeout: 1000)
        try await Task.sleep(milliseconds: previousTimeout + 100)
        subject.value = 20
        try await secondWaitTask.value
    }

    @Test
    func givenBackToBackChanges_whenWaitingForFirstChange_thenUsesObservedSnapshot() async throws {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        let (task, didStartWaiting) = startWait(sut) {
            $0 == 10
        }
        try await didStartWaiting.fulfillment(timeout: 1000)

        subject.value = 10
        subject.value = 20

        try await task.value
    }

    @Test
    func givenWaitIsPending_whenWaitForValueAgain_thenFailsWithInvalidValue() async throws {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        let (pendingTask, didStartWaiting) = startWait(sut) {
            $0 == 10
        }
        try await didStartWaiting.fulfillment(timeout: 1000)

        do {
            try await sut.waitForValue(on: \.value, timeout: 1000) { _ in
                false
            }
            #expect(Bool(false), "Overlapping wait should fail")
        } catch let error as PartoutError {
            #expect(error.code == .invalidValue)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        subject.value = 10
        try await pendingTask.value
    }

    @Test
    func givenWaitIsCancelled_thenFailsWithCancellation() async throws {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        let (task, didStartWaiting) = startWait(sut) { _ in
            false
        }
        try await didStartWaiting.fulfillment(timeout: 1000)
        task.cancel()

        do {
            try await task.value
            #expect(Bool(false), "Cancelled wait should throw")
        } catch is CancellationError {
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        let (nextWaitTask, didStartNextWait) = startWait(sut, timeout: 500) {
            $0 == 10
        }
        try await didStartNextWait.fulfillment(timeout: 1000)
        subject.value = 10
        try await nextWaitTask.value
    }

    @Test
    func givenTemporarySubject_whenInitialValueIsExpected_thenSucceeds() async throws {
        let sut = SafeValueObserver(SomeObject(value: 10))

        try await sut.waitForValue(on: \.value, timeout: 1000) {
            $0 == 10
        }
    }

    @Test
    func givenNegativeTimeout_whenWaitForValue_thenFailsWithInvalidValue() async {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        do {
            try await sut.waitForValue(on: \.value, timeout: -1) { _ in
                false
            }
            #expect(Bool(false), "Negative timeout should fail")
        } catch let error as PartoutError {
            #expect(error.code == .invalidValue)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }
}

// MARK: - Helpers

private extension ValueObserverTests {
    func startWait(
        _ sut: SafeValueObserver<SomeObject>,
        timeout: Int = 1000,
        onValue: @escaping @Sendable (Int) throws -> Bool
    ) -> (Task<Void, Error>, MiniFoundation.Expectation) {
        let didStartWaiting = MiniFoundation.Expectation()
        let task = Task {
            try await sut.waitForValue(on: \.value, timeout: timeout) { newValue in
                Task {
                    await didStartWaiting.fulfill()
                }
                return try onValue(newValue)
            }
        }
        return (task, didStartWaiting)
    }
}

private struct SomeError: Error {
}

private final class SomeObject: NSObject {
    init(value: Int = 0) {
        self.value = value
    }

    @objc var value = 0 {
        willSet {
            willChangeValue(forKey: "value")
        }
        didSet {
            didChangeValue(forKey: "value")
        }
    }
}
