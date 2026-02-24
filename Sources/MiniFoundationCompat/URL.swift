// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C

extension Compat {
    public final class URL: MiniURLProtocol, Hashable, Codable, @unchecked Sendable, CustomStringConvertible {
        private let impl: OpaquePointer

        public init?(string: String) {
            guard let impl = minif_url_create(string) else {
                return nil
            }
            self.impl = impl
        }

        private init(impl: OpaquePointer) {
            self.impl = impl
        }

        deinit {
            minif_url_free(impl)
        }

        public var scheme: String? {
            var count = 0
            guard let str = minif_url_get_scheme(impl, &count) else { return nil }
            return str.sizedString(count: count)
        }

        public var host: String? {
            var count = 0
            guard let str = minif_url_get_host(impl, &count) else { return nil }
            let host = str.sizedString(count: count)
            guard !host.isEmpty else { return nil }
            return host
        }

        public var port: Int? {
            let port = minif_url_get_port(impl)
            return port > 0 ? Int(port) : nil
        }

        public var path: String {
            var count = 0
            var decodedCount = 0
            guard let str = minif_url_get_path(impl, &count) else { return "" }
            let decoded = minif_url_alloc_decoded(str, count, &decodedCount)
            let decodedString = UnsafePointer(decoded).sizedString(count: decodedCount)
            free(decoded)
            return decodedString
        }

        public var lastPathComponent: String {
            var count = 0
            guard let str = minif_url_get_last_path_component(impl, &count) else { return "" }
            return str.sizedString(count: count)
        }

        public var query: String? {
            var count = 0
            guard let str = minif_url_get_query(impl, &count) else { return nil }
            return str.sizedString(count: count)
        }

        public var fragment: String? {
            var count = 0
            guard let str = minif_url_get_fragment(impl, &count) else { return nil }
            return str.sizedString(count: count)
        }

        public var absoluteString: String {
            String(cString: minif_url_get_string(impl))
        }

        // MARK: CustomStringConvertible

        public var description: String {
            absoluteString
        }

        // MARK: Codable

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let impl = minif_url_create(string) else {
                throw MiniFoundationError.decoding
            }
            self.impl = impl
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(absoluteString)
        }
    }
}

extension Compat.URL {
    public static func == (lhs: Compat.URL, rhs: Compat.URL) -> Bool {
        lhs.absoluteString == rhs.absoluteString
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(absoluteString)
    }
}

// MARK: File URLs

// FIXME: #303, Optimistic, implement and test everything here, esp. on Windows

extension Compat.URL {
    public convenience init(fileURLWithPath path: String) {
        let forbidden = "#?"
        guard path.rangeOfCharacter(from: Compat.CharacterSet(charactersIn: forbidden)) == nil else {
            fatalError("Path contains forbidden characters (\(forbidden)): \(path)")
        }
        // FIXME: #303, Does not handle Windows drive unit and backslashes
        let absPath: String
        if path.hasPrefix(String.pathSeparator) {
            absPath = path
        } else {
            let cwd = minif_os_alloc_current_dir()
            absPath = String(cString: cwd) + "/" + path
            free(UnsafeMutableRawPointer(mutating: cwd));
        }
        let urlString = "file://\(absPath)"
        self.init(string: urlString)!
    }

    public func filePath() -> String {
        path
    }

    public func miniAppending(component: String) -> Self {
        let newPath = "\(filePath())\(String.pathSeparator).\(component)"
        return Self(string: newPath)!
    }

    public func miniAppending(path: String) -> Self {
        let newPath = "\(filePath())\(String.pathSeparator).\(path)"
        return Self(string: newPath)!
    }

    public func miniAppending(pathExtension: String) -> Self {
        let newPath = "\(filePath()).\(pathExtension)"
        return Self(string: newPath)!
    }

    public func miniDeletingLastPathComponent() -> Self {
        var pathComponents = filePath().components(separatedBy: String.pathSeparator)
        pathComponents.removeLast()
        return Self(string: pathComponents.joined(separator: String.pathSeparator))!
    }
}

extension String {
    static var pathSeparator: String {
#if os(Windows)
        "\\"
#else
        "/"
#endif
    }

    func appendingPathComponent(_ component: String) -> String {
        "\(self)\(Self.pathSeparator)\(component)"
    }

    func deletingLastPathComponent() -> String {
        var comps = components(separatedBy: Self.pathSeparator)
        comps.removeLast()
        return comps.joined(separator: Self.pathSeparator)
    }
}

private extension UnsafePointer where Pointee == CChar {
    func sizedString(count: Int) -> String {
        withMemoryRebound(to: UInt8.self, capacity: count) {
            let buf = UnsafeBufferPointer(start: $0, count: count)
            return String(decoding: buf, as: UTF8.self)
        }
    }
}
