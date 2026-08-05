// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import PartoutOS
import Testing

struct AppleKeychainTests {
    @Test
    func givenExistingEntry_whenUpdatingPassword_thenPreservesPersistentReference() throws {
        let sut = AppleKeychain(.global, group: nil)
        let username = "AppleKeychainTests.\(UUID().uuidString)"
        defer {
            sut.removePassword(for: username)
        }

        let originalReference = try sut.set(password: "original", for: username)
        let updatedReference = try sut.set(password: "updated", for: username)

        #expect(updatedReference == originalReference)
        #expect(try sut.password(forReference: originalReference) == "updated")
    }

    @Test
    func givenServices_whenUsingSameUsername_thenKeepsEntriesIsolated() throws {
        let username = "AppleKeychainTests.\(UUID().uuidString)"
        let first = AppleKeychain(
            .global,
            service: "AppleKeychainTests.first.\(UUID().uuidString)"
        )
        let second = AppleKeychain(
            .global,
            service: "AppleKeychainTests.second.\(UUID().uuidString)"
        )
        defer {
            first.removePassword(for: username)
            second.removePassword(for: username)
        }

        let firstReference = try first.set(password: "first", for: username)
        let secondReference = try second.set(password: "second", for: username)

        #expect(firstReference != secondReference)
        #expect(try first.password(for: username) == "first")
        #expect(try second.password(for: username) == "second")
        #expect(try first.allPasswordReferences() == [firstReference])
        #expect(try second.allPasswordReferences() == [secondReference])
    }
}
