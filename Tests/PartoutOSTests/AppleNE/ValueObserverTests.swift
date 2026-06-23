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

        Task {
            try await Task.sleep(milliseconds: 100)
            subject.value = 10
            try await Task.sleep(milliseconds: 100)
            subject.value = 20
            try await Task.sleep(milliseconds: 100)
            subject.value = 30
        }

        try await sut.waitForValue(on: \.value, timeout: 1000) { newValue in
            switch newValue {
            case 30:
                print("Succeed on \(newValue)")
                return true

            default:
                print("Ignore \(newValue)")
                return false
            }
        }
    }

    @Test
    func givenSubject_whenValueIsUndesired_thenFails() async {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        Task {
            try await Task.sleep(milliseconds: 100)
            subject.value = 10
            try await Task.sleep(milliseconds: 100)
            subject.value = 20
            try await Task.sleep(milliseconds: 100)
            subject.value = 30
        }

        do {
            try await sut.waitForValue(on: \.value, timeout: 1000) { newValue in
                switch newValue {
                case 20:
                    print("Fail on \(newValue)")
                    throw SomeError()

                case 30:
                    print("Succeed on \(newValue)")
                    return true

                default:
                    print("Ignore \(newValue)")
                    return false
                }
            }
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

        Task {
            try await Task.sleep(milliseconds: 50)
            subject.value = 10
            try await Task.sleep(milliseconds: 200)
            subject.value = 20
        }

        try await sut.waitForValue(on: \.value, timeout: 150) {
            $0 == 10
        }
        try await sut.waitForValue(on: \.value, timeout: 500) {
            $0 == 20
        }
    }

    @Test
    func givenBackToBackChanges_whenWaitingForFirstChange_thenUsesObservedSnapshot() async throws {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        let task = Task {
            try await sut.waitForValue(on: \.value, timeout: 1000) {
                $0 == 10
            }
        }
        try await Task.sleep(milliseconds: 50)

        subject.value = 10
        subject.value = 20

        try await task.value
    }

    @Test
    func givenWaitIsPending_whenWaitForValueAgain_thenFailsWithInvalidValue() async throws {
        let subject = SomeObject()
        let sut = SafeValueObserver(subject)

        let pendingTask = Task {
            try await sut.waitForValue(on: \.value, timeout: 1000) {
                $0 == 10
            }
        }
        try await Task.sleep(milliseconds: 50)

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

        let task = Task {
            try await sut.waitForValue(on: \.value, timeout: 1000) { _ in
                false
            }
        }
        try await Task.sleep(milliseconds: 50)
        task.cancel()

        do {
            try await task.value
            #expect(Bool(false), "Cancelled wait should throw")
        } catch is CancellationError {
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        Task {
            try await Task.sleep(milliseconds: 50)
            subject.value = 10
        }
        try await sut.waitForValue(on: \.value, timeout: 500) {
            $0 == 10
        }
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
