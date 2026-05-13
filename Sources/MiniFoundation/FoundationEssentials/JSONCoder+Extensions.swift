// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension JSONEncoder {
    public static func new() -> JSONEncoder {
        let encoder = JSONEncoder()
        return encoder
    }

    public convenience init(userInfo: [CodingUserInfoKey: Sendable] = [:]) {
        self.init()
        self.userInfo = userInfo
    }
}

extension JSONDecoder {
    public static func new() -> JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }

    public convenience init(userInfo: [CodingUserInfoKey: Sendable] = [:]) {
        self.init()
        self.userInfo = userInfo
    }
}
