// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if MINIF_COMPAT
internal import _MiniFoundation_C

extension String {
    // MARK: - C strings

    public init?(cString: UnsafePointer<CChar>, encoding: String.Encoding) {
        // 1. Compute length up to the null terminator
        var length = 0
        while cString[length] != 0 { length += 1 }
        // 2. Create Data directly from the raw bytes
        let data = Data(bytes: cString, count: length)
        // 3. Decode using the requested encoding
        guard let string = String(data: data, encoding: encoding) else { return nil }
        self = string
    }

    public func cString(using encoding: String.Encoding) -> [CChar] {
        // Convert using String’s data representation for the given encoding
        guard let data = data(using: encoding) else { return [] }
        // Map bytes to CChar and append null terminator
        var result = data.map { CChar(bitPattern: $0) }
        result.append(0)
        return result
    }
}

// MARK: - Tokenization

extension String {
    public func trimmingCharacters(in charset: CharacterSet) -> String {
        var scalars = self.unicodeScalars
        while let first = scalars.first, charset.contains(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last, charset.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    public func enumerateLines(invoking body: @escaping (_ line: String, _ stop: inout Bool) -> Void) {
        let lines = self.components(separatedBy: "\n")
        var stop = false
        for l in lines {
            body(l, &stop)
            if stop { break }
        }
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

    public func rangeOfCharacter(from charset: CharacterSet) -> Range<String.Index>? {
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

    public func replacingOccurrences(of target: String, with replacement: String) -> String {
        components(separatedBy: target).joined(separator: replacement)
    }
}

extension Substring {
    public func trimmingCharacters(in charset: CharacterSet) -> String {
        String(self).trimmingCharacters(in: charset)
    }
}

// MARK: - Formatting

extension String {
    public init(format: String, _ args: Any...) {
        // Convert Swift Any -> CVarArg (only the types we support)
        var allocations: [UnsafeMutablePointer<CChar>] = []
        let cArgs: [CVarArg] = args.map { arg in
            switch arg {
            case let s as String:
                let ptr = minif_strdup(s)
                allocations.append(ptr)
                return UnsafePointer<CChar>(ptr)
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
                let ptr = minif_strdup(s)
                allocations.append(ptr)
                return UnsafePointer<CChar>(ptr)
            }
        }

        // Convert format to C string
        let cFormat = minif_strdup(format.replacingOccurrences(of: "%@", with: "%s"))
        allocations.append(cFormat)

        // Determine output size (+ '\0')
        let size = withVaList(cArgs) { va -> Int32 in
            vsnprintf(nil, 0, cFormat, va)
        } + 1

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer {
            buffer.deallocate()
            for ptr in allocations { free(ptr) }
        }
        _ = withVaList(cArgs) { va in
            vsnprintf(buffer, Int(size), cFormat, va)
        }
        self = String(cString: buffer)
    }
}

// MARK: - I/O

extension String {
    public func write(toFile path: String, encoding: String.Encoding) throws {
        guard let file = FileBuffer(string: self, encoding: encoding) else {
            throw MiniFoundationError.decoding
        }
        try file.write(toFile: path)
    }

    public func append(toFile path: String, encoding: String.Encoding) throws {
        guard let file = FileBuffer(string: self, encoding: encoding) else {
            throw MiniFoundationError.decoding
        }
        try file.append(toFile: path)
    }
}
#endif
