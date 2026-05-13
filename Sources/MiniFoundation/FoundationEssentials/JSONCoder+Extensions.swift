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
