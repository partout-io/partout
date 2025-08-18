// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension WireGuard {

    /// A Base64-encoded key.
    public struct Key: Hashable, Codable, RawRepresentable, Sendable {
        public let rawValue: String

        public init?(rawValue: String) {
            guard Data(base64Encoded: rawValue) != nil else {
                return nil
            }
            self.rawValue = rawValue
        }
    }
}

// MARK: - SensitiveDebugStringConvertible

extension WireGuard.Key: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? rawValue : JSONEncoder.redactedValue
    }
}
