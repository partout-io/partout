// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct PartoutErrorTests {
    @Test
    func givenError_whenWrap_thenReturnsUnhandled() {
        do {
            throw SomeUnmappableError()
        } catch {
            let sut = PartoutError(error)
            #expect(sut == .unhandled(reason: error))
        }
    }

    @Test
    func givenMappableError_whenWrap_thenReturnsMapped() {
        do {
            throw SomeMappableError()
        } catch {
            let sut = PartoutError(error)
            #expect(sut == PartoutError.invalidFields(["example": nil]))
        }
    }

    @Test(arguments: [
        (PartoutError(.authentication), "[PartoutError.authentication]"),
        (PartoutError(.authentication, "userInfo"), "[PartoutError.authentication, userInfo]"),
        (PartoutError(.authentication, "userInfo", SomeDescriptiveError()), "[PartoutError.authentication, userInfo, errorDescription]")
    ])
    func givenError_whenDescribe_thenReturnsDescription(error: PartoutError, expectedDescription: String) {
        #expect(error.debugDescription == expectedDescription)
    }
}

private extension PartoutErrorTests {
    struct SomeUnmappableError: Error {
    }

    struct SomeMappableError: Error, PartoutErrorMappable {
        var asPartoutError: PartoutError {
            .invalidFields(["example": nil])
        }
    }

    struct SomeDescriptiveError: Error, LocalizedError {
        var errorDescription: String? {
            "errorDescription"
        }
    }
}
