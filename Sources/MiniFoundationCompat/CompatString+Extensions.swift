// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C

extension String {
    // MARK: Initializers

    // FIXME: #303, Only on file URLs
    public init(contentsOf url: Compat.URL, encoding: Compat.StringEncoding) throws {
        try self.init(contentsOfFile: url.filePath(), encoding: encoding)
    }

    // FIXME: #303, Only on file URLs
    public init(contentsOf url: Compat.URL, usedEncoding: inout Compat.StringEncoding) throws {
        try self.init(contentsOfFile: url.filePath(), usedEncoding: &usedEncoding)
    }

    public init(contentsOfFile path: String, encoding: Compat.StringEncoding) throws {
        let bytes = try FileBuffer(contentsOfFile: path).bytes
        guard let decoded = encoding.decode(bytes) else {
            throw MiniFoundationError.encoding
        }
        self = decoded
    }

    public init?(data: Compat.Data, encoding: Compat.StringEncoding) {
        guard let decoded = encoding.decode(data.bytes) else { return nil }
        self = decoded
    }

    public init(contentsOfFile path: String, usedEncoding: inout Compat.StringEncoding) throws {
        let bytes = try FileBuffer(contentsOfFile: path).bytes
        // Try strict UTF-8 first
        let decodedUtf8 = String(decoding: bytes, as: UTF8.self)
        if Array(decodedUtf8.utf8) == bytes {
            usedEncoding = .utf8
            self = decodedUtf8
        } else if bytes.allSatisfy({ $0 < 128 }) {
            // Try ASCII (strict)
            usedEncoding = .ascii
            self = bytes.map {
                Character(UnicodeScalar($0))
            }.reduce("") {
                $0 + String($1)
            }
        } else {
            // Neither valid UTF-8 nor pure ASCII
            throw MiniFoundationError.encoding
        }
    }

    public init?(cString: UnsafePointer<CChar>, encoding: Compat.StringEncoding) {
        // build byte array until NUL
        let len = strlen(cString)
        let buffer = UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(cString)), count: Int(len))
        let bytes = Array(buffer)
        guard let s = encoding.decode(bytes) else { return nil }
        self = s
    }

    // MARK: - Methods

    public func components(separatedBy separator: String) -> [String] {
        guard !separator.isEmpty else { return [self] }
        var result: [String] = []
        var buffer = self
        while let r = buffer.range(of: separator) {
            result.append(String(buffer[..<r.lowerBound]))
            buffer = String(buffer[r.upperBound...])
        }
        result.append(buffer)
        return result
    }

    public func trimmingCharacters(in charset: Compat.CharacterSet) -> String {
        var scalars = self.unicodeScalars
        while let first = scalars.first, charset.contains(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last, charset.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    public func cString(using encoding: Compat.StringEncoding) -> [CChar] {
        (encoding.encode(self) ?? []).map { CChar(bitPattern: $0) } + [0]
    }

    public func enumerateLines(invoking body: @escaping (_ line: String, _ stop: inout Bool) -> Void) {
        let lines = self.components(separatedBy: "\n")
        var stop = false
        for l in lines {
            body(l, &stop)
            if stop { break }
        }
    }

    public func replacingOccurrences(of target: String, with replacement: String) -> String {
        components(separatedBy: target).joined(separator: replacement)
    }

    public func replacingOccurrences(of charset: Compat.CharacterSet, with replacement: String) -> String {
        var out = String()
        out.reserveCapacity(self.count)
        var shouldReplace = false
        for char in self {
            // A Character can be made of multiple scalars.
            // If *any* scalar is in the set → replace.
            shouldReplace = false
            for scalar in char.unicodeScalars {
                if charset.contains(scalar) {
                    shouldReplace = true
                    break
                }
            }
            if shouldReplace {
                out.append(replacement)
            } else {
                out.append(char)
            }
        }
        return out
    }

    public func range(of substring: String) -> Range<String.Index>? {
        guard !substring.isEmpty else { return startIndex..<startIndex }
        var current = startIndex
        while current < endIndex {
            if self[current...].starts(with: substring) {
                let upper = index(current, offsetBy: substring.count)
                return current..<upper
            }
            current = index(after: current)
        }
        return nil
    }

    public func rangeOfCharacter(from charset: Compat.CharacterSet) -> Range<String.Index>? {
        for i in self.unicodeScalars.indices {
            let scalar = self.unicodeScalars[i]
            if charset.contains(scalar) {
                let lower = index(startIndex, offsetBy: self.unicodeScalars.distance(from: self.unicodeScalars.startIndex, to: i))
                let upper = index(after: lower)
                return lower..<upper
            }
        }
        return nil
    }

    public func write(toFile path: String, encoding: Compat.StringEncoding) throws {
        guard let file = FileBuffer(string: self, encoding: encoding) else {
            throw MiniFoundationError.decoding
        }
        try file.write(toFile: path)
    }

    public func append(toFile path: String, encoding: Compat.StringEncoding) throws {
        guard let file = FileBuffer(string: self, encoding: encoding) else {
            throw MiniFoundationError.decoding
        }
        try file.append(toFile: path)
    }

    public func strippingWhitespaces() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: .whitespaces, with: " ")
    }
}

extension Substring {
    public func trimmingCharacters(in charset: Compat.CharacterSet) -> String {
        String(self).trimmingCharacters(in: charset)
    }
}

// MARK: - Formatting

extension String {
    // FIXME: #303, Test, look for memory leaks
    public init(format: String, _ args: Any...) {
        // Convert Swift Any -> CVarArg (only the types we support)
        let cArgs: [CVarArg] = args.map { arg in
            switch arg {
            case let s as String:
                return UnsafePointer<CChar>(minif_strdup(s))
            case let i as Int:
                return i
            case let i as Int8:
                return i
            case let i as Int16:
                return i
            case let i as Int32:
                return i
            case let i as Int64:
                return i
            case let u as UInt:
                return u
            case let u as UInt8:
                return u
            case let u as UInt16:
                return u
            case let u as UInt32:
                return u
            case let u as UInt64:
                return u
            case let d as Double:
                return d
            default:
                // Fall back to debugDescription
                let s = "\(arg)"
                return UnsafePointer<CChar>(minif_strdup(s))
            }
        }

        // Convert format to C string
        let cFormat = minif_strdup(format.replacingOccurrences(of: "%@", with: "%s"))
        defer {
            free(cFormat)
            // free strdup’d string args
            for a in cArgs {
                if let p = a as? UnsafePointer<CChar> {
                    free(UnsafeMutablePointer(mutating: p))
                }
            }
        }

        // Determine output size (+ '\0')
        let size = withVaList(cArgs) { va -> Int32 in
            vsnprintf(nil, 0, cFormat, va)
        } + 1

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        _ = withVaList(cArgs) { va in
            vsnprintf(buffer, Int(size), cFormat, va)
        }
        self = String(cString: buffer)
    }
}

// MARK: - Newlines

extension String {
    public static var newlines: String { "\n" }
}

// MARK: - Data Encoding

extension String {
    public func data(using encoding: Compat.StringEncoding) -> Compat.Data? {
        encoding.encode(self).map {
            Compat.Data($0)
        }
    }
}

extension Compat {
    public enum StringEncoding {
        case ascii
        case utf8
    }
}

// MARK: - Helpers

extension FileBuffer {
    public init?(string: String, encoding: Compat.StringEncoding) {
        guard let bytes = string.data(using: encoding)?.bytes else { return nil }
        self.init(bytes: bytes)
    }

    public var string: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

private extension Compat.StringEncoding {
    // FIXME: #303, Test, probably inefficient
    // Return `String?` — nil if decoding failed (invalid for that encoding)
    func decode(_ bytes: [UInt8]) -> String? {
        switch self {
        case .ascii:
            guard !bytes.contains(where: { $0 >= 128 }) else { return nil }
            return String(bytes.map { Character(UnicodeScalar($0)) })
        case .utf8:
            // Decode using stdlib, then validate by round-trip
            let decoded = String(decoding: bytes, as: UTF8.self)
            guard Array(decoded.utf8) == bytes else { return nil }
            return decoded
        }
    }

    func encode(_ string: String) -> [UInt8]? {
        switch self {
        case .ascii:
            let bytes = Array(string.utf8)
            guard !bytes.contains(where: { $0 >= 128 }) else { return nil }
            return bytes
        case .utf8:
            return Array(string.utf8)
        }
    }
}
