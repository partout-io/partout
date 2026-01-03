// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Abstract representation of a type-to-text encoder.
public protocol TextEncoder {
    func encode<T>(_ value: T) throws -> String where T: Encodable
}

/// Abstract representation of a text-to-type decoder.
public protocol TextDecoder {
    func decode<T>(_ type: T.Type, string: String) throws -> T where T: Decodable
}
