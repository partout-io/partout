// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C

// FIXME: #303, Test file I/O, esp. on Windows

extension Compat {
    public final class FileManager {
        public static let `default`: MiniFileManager = FileManager()

        private init() {
        }

        public var miniTemporaryDirectory: MiniURLProtocol {
            let dir = minif_os_temp_dir()
            defer { free(UnsafeMutableRawPointer(mutating: dir)) }
            return URL(fileURLWithPath: "\(String(cString: dir))")
        }

        public func makeTemporaryURL(filename: String) -> MiniURLProtocol {
            let dir = minif_os_temp_dir()
            defer { free(UnsafeMutableRawPointer(mutating: dir)) }
            return URL(fileURLWithPath: "\(String(cString: dir))/\(filename)")
        }
    }
}

#if !os(Windows)

extension Compat.FileManager: MiniFileManager {
    public func miniContentsOfDirectory(at url: MiniURLProtocol) throws -> [MiniURLProtocol] {
        let path = url.filePath()
        guard let dir = opendir(path) else {
            throw MiniFoundationError.file(.failedToOpenDirectory(path))
        }
        defer {
            closedir(dir)
        }
        var result: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                    String(cString: ptr)
                }
            }
            guard name != "." && name != ".." else { continue }
            result.append(name)
        }
        return result.map {
            Compat.URL(fileURLWithPath: path.appendingPathComponent($0))
        }
    }

    public func miniMoveItem(at url: MiniURLProtocol, to: MiniURLProtocol) throws {
        let path = url.filePath()
        let toPath = to.filePath()
        guard rename(path, toPath) == 0 else {
            throw MiniFoundationError.file(.failedToMove(path, toPath))
        }
    }

    public func miniRemoveItem(at url: MiniURLProtocol) throws {
        let path = url.filePath()
        guard unlink(path) == 0 else {
            throw MiniFoundationError.file(.failedToRemove(path))
        }
    }

    public func miniAttributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any] {
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else {
            throw MiniFoundationError.file(.failedToStat(path))
        }
        var attributes: [MiniFileAttribute: Any] = [:]
        attributes[.size] = UInt64(statBuf.st_size)
#if canImport(Darwin)
        let ctime = statBuf.st_ctimespec.tv_sec
        let mtime = statBuf.st_mtimespec.tv_sec
#else
        let ctime = statBuf.st_ctim.tv_sec
        let mtime = statBuf.st_mtim.tv_sec
#endif
        attributes[.creationDate] = Compat.Date(timeIntervalSince1970: Compat.TimeInterval(ctime))
        attributes[.modificationDate] = Compat.Date(timeIntervalSince1970: Compat.TimeInterval(mtime))
        return attributes
    }

    public func fileExists(atPath path: String) -> Bool {
        var statBuf = stat()
        return stat(path, &statBuf) == 0
    }
}

#else

extension Compat.FileManager: MiniFileManager {
    public func miniContentsOfDirectory(at url: MiniURLProtocol) throws -> [MiniURLProtocol] {
        let path = url.filePath()
        var findData = WIN32_FIND_DATAW()
        let searchPath = path + "\\*"
        let handle = searchPath.withWideCString { ptr in
            FindFirstFileW(ptr, &findData)
        }
        guard handle != INVALID_HANDLE_VALUE else {
            throw MiniFoundationError.file(.failedToOpenDirectory(path))
        }
        defer { FindClose(handle) }

        var result: [String] = []
        repeat {
            let name = withUnsafePointer(to: &findData.cFileName.0) { ptr in
                let len = wcslen(ptr)
                let buf = UnsafeBufferPointer(start: ptr, count: Int(len))
                return String(decoding: buf, as: UTF16.self)
            }
            if name != "." && name != ".." {
                result.append(name)
            }
        } while FindNextFileW(handle, &findData)
        return result.map {
            Compat.URL(fileURLWithPath: $0)
        }
    }

    public func miniMoveItem(at url: MiniURLProtocol, to: MiniURLProtocol) throws {
        let fromPath = url.filePath()
        let toPath = url.filePath()
        try fromPath.withWideCString { wfrom in
            try toPath.withWideCString { wto in
                guard MoveFileW(wfrom, wto) else {
                    throw MiniFoundationError.file(.failedToMove(fromPath, toPath))
                }
            }
        }
    }

    public func miniRemoveItem(at url: MiniURLProtocol) throws {
        let path = url.filePath()
        try path.withWideCString { wpath in
            guard DeleteFileW(wpath) else {
                throw MiniFoundationError.file(.failedToRemove(path))
            }
        }
    }

    public func miniAttributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any] {
        var attr = WIN32_FILE_ATTRIBUTE_DATA()
        try path.withWideCString { wpath in
            guard GetFileAttributesExW(wpath, GetFileExInfoStandard, &attr) else {
                throw MiniFoundationError.file(.failedToStat(path))
            }
        }
        let creation = Compat.Date(timeIntervalSince1970: filetimeToUnixTime(attr.ftCreationTime))
        let modification = Compat.Date(timeIntervalSince1970: filetimeToUnixTime(attr.ftLastWriteTime))
        let size = UInt64(attr.nFileSizeHigh) << 32 | UInt64(attr.nFileSizeLow)
        return [.size: size, .creationDate: creation, .modificationDate: modification]
    }

    public func fileExists(atPath path: String) -> Bool {
        path.withWideCString { wpath in
            let attr = GetFileAttributesW(wpath)
            return attr != INVALID_FILE_ATTRIBUTES
        }
    }
}

private extension String {
    func withWideCString<Result>(_ body: (UnsafePointer<UInt16>) throws -> Result) rethrows -> Result {
        let utf16 = Array(self.utf16) + [0] // Null-terminated
        return try utf16.withUnsafeBufferPointer { ptr in
            try body(ptr.baseAddress!)
        }
    }
}

private func filetimeToUnixTime(_ ft: FILETIME) -> Compat.TimeInterval {
    let fileTime = UInt64(ft.dwLowDateTime) | (UInt64(ft.dwHighDateTime) << 32)
    // FILETIME is in 100-nanosecond intervals since Jan 1, 1601
    return Compat.TimeInterval(fileTime) / 10_000_000 - 11_644_473_600
}

#endif
