// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension CodingUserInfoKey {
    public static let moduleDecoder = CodingUserInfoKey(rawValue: "moduleDecoder")!
    public static let legacySwiftEncoding = CodingUserInfoKey(rawValue: "legacySwiftEncoding")!
}

extension Dictionary where Key == CodingUserInfoKey, Value == Any {
    public var usesLegacySwiftEncoding: Bool {
        self[.legacySwiftEncoding] as? Bool == true
    }
}
