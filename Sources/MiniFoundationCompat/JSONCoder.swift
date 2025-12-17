// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if !MINIF_COMPAT
import MiniFoundationCore
#endif

extension Compat {
    public final class JSONEncoder: Sendable {
        public init() {}

        public func encode<T>(_ value: T) throws -> Compat.Data where T: Encodable {
            // FIXME: #228, JSONEncoder
            throw MiniFoundationError.encoding
        }
    }

    public final class JSONDecoder: Sendable {
        private let userInfo: [CodingUserInfoKey: Sendable]

        public init(userInfo: [CodingUserInfoKey: Sendable] = [:]) {
            self.userInfo = userInfo
        }

        public func decode<T>(_ type: T.Type, from data: Compat.Data) throws -> T where T: Decodable {
            // FIXME: #228, JSONDecoder
            throw MiniFoundationError.decoding
        }
    }
}
