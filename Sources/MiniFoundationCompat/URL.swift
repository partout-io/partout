// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

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
            guard let str = minif_url_get_scheme(impl) else { return nil }
            return String(cString: str)
        }

        public var host: String? {
            guard let str = minif_url_get_host(impl) else { return nil }
            return String(cString: str)
        }

        public var port: Int? {
            let port = minif_url_get_port(impl)
            return port > 0 ? Int(port) : nil
        }

        public var path: String {
            guard let str = minif_url_get_path(impl) else { return "" }
            return "/" + String(cString: str)
        }

        public var lastPathComponent: String {
            guard let str = minif_url_alloc_last_path(impl) else { return "" }
            defer { str.deallocate() }
            return String(cString: str)
        }

        public var query: String? {
            guard let str = minif_url_get_query(impl) else { return nil }
            return String(cString: str)
        }

        public var fragment: String? {
            guard let str = minif_url_get_fragment(impl) else { return nil }
            return String(cString: str)
        }

        public var absoluteString: String {
            String(cString: minif_url_get_string(impl))
        }

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
