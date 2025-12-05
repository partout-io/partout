// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

extension Compat {
    public struct FileBuffer {
        public let bytes: [UInt8]

        public init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        public init?(string: String) {
            guard let bytes = string.data(using: .utf8)?.bytes else { return nil }
            self.bytes = bytes
        }

        public init(contentsOfFile path: String) throws {
            guard let file = fopen(path, "rb") else { throw lastError }
            defer { fclose(file) }
            fseek(file, 0, SEEK_END)
            let size = Int(ftell(file))
            fseek(file, 0, SEEK_SET)
            guard size >= 0 else { throw lastError }
            var buffer = [UInt8](repeating: 0, count: size)
            let readBytes = fread(&buffer, 1, size, file)
            guard readBytes == size else {
                throw MiniFoundationError.io(Int(EIO))
            }
            bytes = buffer
        }

        public func write(toFile path: String) throws {
            guard let file = fopen(path, "wb") else { throw lastError }
            defer { fclose(file) }
            let written = fwrite(bytes, 1, bytes.count, file)
            guard written == bytes.count else {
                throw MiniFoundationError.io(Int(EIO))
            }
        }

        public func append(toFile path: String) throws {
            guard let file = fopen(path, "ab") else { throw lastError }
            defer { fclose(file) }
            let written = fwrite(bytes, 1, bytes.count, file)
            guard written == bytes.count else {
                throw MiniFoundationError.io(Int(EIO))
            }
        }

        public var string: String {
            String(decoding: bytes, as: UTF8.self)
        }
    }
}

private var lastError: Error {
    MiniFoundationError.io(Int(errno))
}
