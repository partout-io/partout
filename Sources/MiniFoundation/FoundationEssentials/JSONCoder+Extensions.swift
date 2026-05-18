// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension JSONEncoder {
    public static func shared() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    public convenience init(userInfo: [CodingUserInfoKey: Sendable] = [:]) {
        self.init()
        self.userInfo = userInfo
    }

    public func encodeJSON<T>(_ value: T) throws -> String where T: Encodable {
        let data = try encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MiniFoundationError.encoding
        }
        return json
    }
}

extension JSONDecoder {
    public static func shared() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    public convenience init(userInfo: [CodingUserInfoKey: Sendable] = [:]) {
        self.init()
        self.userInfo = userInfo
    }
}
