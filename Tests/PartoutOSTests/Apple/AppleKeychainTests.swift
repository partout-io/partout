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
}
