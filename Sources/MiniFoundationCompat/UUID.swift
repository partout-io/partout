// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C

extension Compat {
    public struct UUID: Hashable, Codable, Sendable, CustomStringConvertible {
        public let uuidString: String

        public init() {
            guard let str = minif_uuid_create() else {
                fatalError("minif_uuid_create() failed")
            }
            uuidString = String(cString: str).uppercased()
            free(UnsafeMutableRawPointer(mutating: str))
        }

        public init?(uuidString: String) {
            guard minif_uuid_validate(uuidString) else { return nil }
            self.uuidString = uuidString
        }

        public var description: String {
            uuidString
        }
    }
}
