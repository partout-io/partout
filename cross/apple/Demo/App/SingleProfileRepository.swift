// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutRuntime

public final class SingleProfileRepository: Sendable {
    private static let profileId = UUID(uuidString: "B316870C-4970-4981-8CE7-95700B2C33EC")!

    private let profile: Profile

    public init(profile: Profile) {
        precondition(profile.id == Self.profileId, "Unexpected profile ID: \(profile.id)")
        self.profile = profile
    }

    public var source: AsyncStream<ProfilesEvent> {
        let profile = self.profile
        return AsyncStream { continuation in
            continuation.yield(.snapshot([profile]))
            continuation.finish()
        }
    }
}
