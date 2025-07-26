// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import _PartoutVendorsAppleNE
import Foundation
import PartoutCore
import XCTest

final class ValueObserverTests: XCTestCase {
    func test_givenSubject_whenValueIsExpected_thenSucceeds() async throws {
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

    func test_givenSubject_whenValueIsUndesired_thenFails() async {
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
            XCTFail("Undesired value should fail")
        } catch {
            XCTAssert(type(of: error) == SomeError.self)
        }
    }

    func test_givenSubject_whenValueIsDelayed_thenFailsWithTimeout() async {
        let subject = SomeObject()
        let sut = ValueObserver(subject)

        do {
            try await sut.waitForValue(on: \.value, timeout: 200) { _ in
                false
            }
            XCTFail("Should time out")
        } catch let error as PartoutError {
            XCTAssertEqual(error.code, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
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
