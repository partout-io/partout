//
//  ValueObserverTests.swift
//  Partout
//
//  Created by Davide De Rosa on 3/29/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

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
