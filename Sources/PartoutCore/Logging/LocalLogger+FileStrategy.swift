// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension LocalLogger {
    public final class FileStrategy: LocalLogger.Strategy {
        public init() {
        }

        public func size(of path: String) -> UInt64 {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                return attrs[.size] as? UInt64 ?? 0
            } catch {
                NSLog("LocalLogger: Unable to read current log size: \(error)")
                return 0
            }
        }

        public func rotate(path: String, withLines oldLines: [String]?) throws {
            let suffix = Int(Date().timeIntervalSince1970).description
            let rotatedPath = "\(path).\(suffix)"

            try FileManager.default.moveItem(atPath: path, toPath: rotatedPath)
            if let oldLines {
                try write(lines: oldLines, to: rotatedPath)
            }
        }

        public func append(lines: [String], to path: String) throws {
            try write(lines: lines, to: path)
        }

        public func availableLogs(at path: String) -> [Date: String] {
            let parent = path.deletingLastPathComponent()
            let prefix = path.lastPathComponent
            do {
                let fm = FileManager.default
                let contents = try fm.contentsOfDirectory(atPath: parent)
                return try contents.reduce(into: [:]) { found, item in
                    let filename = item.lastPathComponent
                    guard filename.hasPrefix(prefix) else {
                        return
                    }
                    let attrs = try fm.attributesOfItem(atPath: item)
                    guard let mdate = attrs[.modificationDate] as? Date else {
                        return
                    }
                    found[mdate] = item
                }
            } catch {
                return [:]
            }
        }

        public func purgeLogs(at path: String, beyond maxAge: TimeInterval?, includingCurrent: Bool) {
            let logs = availableLogs(at: path)
            // Filter max age if provided, else purge everything (no date is >= .max)
            let minDate = maxAge.map {
                Date(timeIntervalSince1970: -$0)
            }
            logs.forEach { date, logPath in
                guard includingCurrent || logPath != path else { // skip current log
                    return
                }
                guard minDate == nil || date >= minDate! else {
                    try? FileManager.default.removeItem(atPath: logPath)
                    return
                }
            }
        }
    }
}

private extension LocalLogger.FileStrategy {
    func write(lines: [String], to path: String) throws {
        do {
            let mf = FileManager.default
            let textToAppend = (lines + [""]).joined(separator: "\n")
            guard mf.fileExists(atPath: path) else {
                try textToAppend.write(toFile: path)
                return
            }
            try textToAppend.append(toFile: path)
        } catch {
            NSLog("LocalLogger: Unable to save log to disk: \(error)")
        }
    }
}
