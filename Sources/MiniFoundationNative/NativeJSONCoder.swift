// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension JSONDecoder {
    public convenience init(userInfo: [CodingUserInfoKey: Sendable] = [:]) {
        self.init()
        self.userInfo = userInfo
    }
}
