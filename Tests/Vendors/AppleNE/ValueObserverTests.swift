// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import _PartoutVendorsAppleNE
import Foundation
import PartoutCore
import Testing

struct ValueObserverTests {
    @Test
    func givenSubject_whenValueIsExpected_thenSucceeds() async throws {
        let subject = SomeObject()
        let sut = ValueObserver(subject)

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
        let sut = ValueObserver(subject)

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
        let sut = ValueObserver(subject)

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
}

// MARK: - Helpers

private struct SomeError: Error {
}

private final class SomeObject: NSObject {
    @objc var value = 0 {
        willSet {
            willChangeValue(forKey: "value")
        }
        didSet {
            didChangeValue(forKey: "value")
        }
    }
}
