// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

// FIXME: #228, Test file I/O, esp. on Windows

extension Compat {
    public final class FileManager {
        public static let `default`: MiniFileManager = FileManager()

        private init() {
        }

        public func makeTemporaryPath(filename: String) -> String {
            let dir = minif_os_temp_dir()
            defer {
                dir.deallocate()
            }
            return "\(String(cString: dir))/\(filename)"
        }
    }
}

#if !os(Windows)

extension Compat.FileManager: MiniFileManager {
    public func contentsOfDirectory(atPath path: String) throws -> [String] {
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
        return result
    }

    public func attributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any] {
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

    public func moveItem(atPath path: String, toPath: String) throws {
        guard rename(path, toPath) == 0 else {
            throw MiniFoundationError.file(.failedToMove(path, toPath))
        }
    }

    public func removeItem(atPath path: String) throws {
        guard unlink(path) == 0 else {
            throw MiniFoundationError.file(.failedToRemove(path))
        }
    }

    public func fileExists(atPath path: String) -> Bool {
        var statBuf = stat()
        return stat(path, &statBuf) == 0
    }
}

#else

extension Compat.FileManager {
    public func contentsOfDirectory(atPath path: String) throws -> [String] {
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
            let name = String(decodingCString: &findData.cFileName.0, as: UTF16.self)
            if name != "." && name != ".." {
                result.append(name)
            }
        } while FindNextFileW(handle, &findData) != 0
        return result
    }

    public func attributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any] {
        var attr = WIN32_FILE_ATTRIBUTE_DATA()
        guard GetFileAttributesExW(path.wideCString, GetFileExInfoStandard, &attr) != 0 else {
            throw MiniFoundationError.file(.failedToStat(path))
        }
        let creation = Date(timeIntervalSince1970: filetimeToUnixTime(attr.ftCreationTime))
        let modification = Date(timeIntervalSince1970: filetimeToUnixTime(attr.ftLastWriteTime))
        let size = UInt64(attr.nFileSizeHigh) << 32 | UInt64(attr.nFileSizeLow)
        return [.size: size, .creationDate: creation, .modificationDate: modification]
    }

    public func moveItem(atPath path: String, toPath: String) throws {
        guard MoveFileW(path.wideCString, toPath.wideCString) != 0 else {
            throw MiniFoundationError.file(.failedToMove(path, toPath))
        }
    }

    public func removeItem(atPath path: String) throws {
        guard DeleteFileW(path.wideCString) != 0 else {
            throw MiniFoundationError.file(.failedToRemove(path))
        }
    }

    public func fileExists(atPath path: String) -> Bool {
        let attr = GetFileAttributesW(path.wideCString)
        return attr != INVALID_FILE_ATTRIBUTES
    }
}

private extension String {
    func withWideCString<Result>(_ body: (UnsafePointer<WCHAR>) -> Result) -> Result {
        var utf16 = Array(self.utf16) + [0] // Null-terminated
        return utf16.withUnsafeBufferPointer { ptr in
            body(ptr.baseAddress!)
        }
    }
}

private func filetimeToUnixTime(_ ft: FILETIME) -> TimeInterval {
    let fileTime = UInt64(ft.dwLowDateTime) | (UInt64(ft.dwHighDateTime) << 32)
    // FILETIME is in 100-nanosecond intervals since Jan 1, 1601
    return TimeInterval(fileTime) / 10_000_000 - 11_644_473_600
}

#endif
