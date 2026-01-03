// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import MiniFoundation
import Testing

struct UUIDTests {
    @Test
    func generation() async throws {
        #expect(UUID().uuidString.count == 36)
    }

    @Test(arguments: [
        "550e8400-e29b-41d4-a716-446655440000",
        "123e4567-e89b-12d3-a456-426614174000",
        "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        "e02fd0e4-00fd-090A-ca30-0d00a0038ba0",
        "9f8c4d2b-6e4a-4c6f-9f2c-7e6b8d1a1f10",
        "3d813cbb-47fb-32ba-91df-831e1593ac29",
        "1c6b1470-0a1b-41f2-86a8-6c4f8d6b10b0",
        "7c9e6679-7425-40de-944b-e07fc1f90ae7",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf6"
        // Non-hyphened is not recognized by Foundation
//        "550e8400e29b41d4a716446655440000",
//        "3d813cbb47fb32ba91df831e1593ac29"
    ])
    func valid(string: String) async throws {
        #expect(UUID(uuidString: string)?.uuidString.lowercased() == string.lowercased())
    }

    @Test(arguments: [
        "123e4567-e89b-12d3-a456-42661417400",
        "g47ac10b-58cc-4372-a567-0e02b2c3d479",
        "6ba7b810-9dad-11d1-80b4-00c04fd430c",
        "e02fd0e4-00fd-090A-ca30-0d00a0038baZ",
        "9f8c4d2b-6e4a-4c6f-9f2c-7e6b8d1a1f1",
        "1c6b1470-0a1b-41f2-86a8-6c4f8d6b10b00",
        "7c9e6679-7425-40de-944b-e07fc1f90aeg",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf"
    ])
    func invalid(string: String) async throws {
        #expect(UUID(uuidString: string) == nil)
    }
}
