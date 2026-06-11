// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension PartoutError {
    public struct Code: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ string: String) {
            rawValue = string
        }
    }
}
