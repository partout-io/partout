// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

struct FileBuffer {
    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(contentsOfFile path: String) throws {
        guard let file = minif_fopen(path, "rb") else { throw lastError }
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

    func write(toFile path: String) throws {
        guard let file = minif_fopen(path, "wb") else { throw lastError }
        defer { fclose(file) }
        let written = fwrite(bytes, 1, bytes.count, file)
        guard written == bytes.count else {
            throw MiniFoundationError.io(Int(EIO))
        }
    }

    func append(toFile path: String) throws {
        guard let file = minif_fopen(path, "ab") else { throw lastError }
        defer { fclose(file) }
        let written = fwrite(bytes, 1, bytes.count, file)
        guard written == bytes.count else {
            throw MiniFoundationError.io(Int(EIO))
        }
    }
}

private var lastError: Error {
#if !os(Windows)
    MiniFoundationError.io(Int(errno))
#else
    MiniFoundationError.io()
#endif
}
