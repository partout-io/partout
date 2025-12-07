// SPDX-FileCopyrightText: 2025 Tomáš Znamenáček
//
// SPDX-License-Identifier: MIT

private struct InitializationError: Error {}

extension JSON {

    /// Create a JSON value from anything.
    ///
    /// Argument has to be a valid JSON structure: A `Double`, `Int`, `String`,
    /// `Bool`, an `Array` of those types or a `Dictionary` of those types.
    public init(_ value: Any) throws {
        // The insane verbosity of the Int variants versus the
        // use of NSNumber is preferred to avoid a heavy dependency
        // on Foundation. Likewise, nulls are not handled either
        // to avoid NSNull.
        switch value {
        case let opt as Any? where opt == nil:
            self = .null
        case let str as String:
            self = .string(str)
        case let bool as Bool:
            self = .bool(bool)
        case let array as [Any]:
            self = .array(try array.map(JSON.init))
        case let dict as [String: Any]:
            self = .object(try dict.mapValues(JSON.init))
        case let n as Double:
            self = .number(n)
        case let n as Float:
            self = .number(Double(n))
        case let n as Int:
            self = .number(Double(n))
        case let n as Int8:
            self = .number(Double(n))
        case let n as Int16:
            self = .number(Double(n))
        case let n as Int32:
            self = .number(Double(n))
        case let n as Int64:
            self = .number(Double(n))
        case let n as UInt:
            self = .number(Double(n))
        case let n as UInt8:
            self = .number(Double(n))
        case let n as UInt16:
            self = .number(Double(n))
        case let n as UInt32:
            self = .number(Double(n))
        case let n as UInt64:
            self = .number(Double(n))
        default:
            throw InitializationError()
        }
    }
}

#if !MINI_FOUNDATION_COMPAT
extension JSON {

    /// Create a JSON value from an `Encodable`. This will give you access to the “raw”
    /// encoded JSON value the `Encodable` is serialized into.
    public init<T: Encodable>(encodable: T) throws {
        let encoded = try JSONEncoder().encode(encodable)
        self = try JSONDecoder().decode(JSON.self, from: encoded)
    }
}
#endif

extension JSON: ExpressibleByBooleanLiteral {

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSON: ExpressibleByNilLiteral {

    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSON: ExpressibleByArrayLiteral {

    public init(arrayLiteral elements: JSON...) {
        self = .array(elements)
    }
}

extension JSON: ExpressibleByDictionaryLiteral {

    public init(dictionaryLiteral elements: (String, JSON)...) {
        var object: [String: JSON] = [:]
        for (k, v) in elements {
            object[k] = v
        }
        self = .object(object)
    }
}

extension JSON: ExpressibleByFloatLiteral {

    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension JSON: ExpressibleByIntegerLiteral {

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension JSON: ExpressibleByStringLiteral {

    public init(stringLiteral value: String) {
        self = .string(value)
    }
}
