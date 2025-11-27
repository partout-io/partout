// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

public struct UUID: Hashable, Codable, Sendable {
    public init() {
    }

    public init?(uuidString: String) {
        nil
    }

    public var uuidString: String {
        ""
    }
}
