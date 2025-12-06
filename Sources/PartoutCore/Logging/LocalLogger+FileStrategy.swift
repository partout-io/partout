// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension LocalLogger {
    public final class FileStrategy: LocalLogger.Strategy {
        public init() {
        }

        public func size(of url: URL) -> UInt64 {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.filePath())
                return attrs[.size] as? UInt64 ?? 0
            } catch {
                NSLog("LocalLogger: Unable to read current log size: \(error)")
                return 0
            }
        }

        public func rotate(url: URL, withLines oldLines: [String]?) throws {
            let suffix = Int(Date().timeIntervalSince1970).description
            let rotatedURL = url.appendingPathExtension(suffix)

            try FileManager.default.miniMoveItem(at: url, to: rotatedURL)
            if let oldLines {
                try write(lines: oldLines, to: rotatedURL)
            }
        }

        public func append(lines: [String], to url: URL) throws {
            try write(lines: lines, to: url)
        }

        public func availableLogs(at url: URL) -> [Date: URL] {
            let parent = url.deletingLastPathComponent()
            let prefix = url.lastPathComponent
            do {
                let fm = FileManager.default
                let contents = try fm.miniContentsOfDirectory(at: parent)
                return try contents.reduce(into: [:]) { found, item in
                    let filename = item.lastPathComponent
                    guard filename.hasPrefix(prefix) else {
                        return
                    }
                    let attrs = try fm.attributesOfItem(atPath: item.filePath())
                    guard let mdate = attrs[.modificationDate] as? Date else {
                        return
                    }
                    guard let itemURL = item as? URL else {
                        assertionFailure("Wrong URL type from MiniFoundation?")
                        return
                    }
                    found[mdate] = itemURL
                }
            } catch {
                return [:]
            }
        }

        public func purgeLogs(at url: URL, beyond maxAge: TimeInterval?, includingCurrent: Bool) {
            let logs = availableLogs(at: url)
            // Filter max age if provided, else purge everything (no date is >= .max)
            let minDate = maxAge.map {
                Date(timeIntervalSince1970: -$0)
            }
            logs.forEach { date, logURL in
                guard includingCurrent || logURL != url else { // skip current log
                    return
                }
                guard minDate == nil || date >= minDate! else {
                    try? FileManager.default.miniRemoveItem(at: logURL)
                    return
                }
            }
        }
    }
}

private extension LocalLogger.FileStrategy {
    func write(lines: [String], to url: URL) throws {
        do {
            let mf = FileManager.default
            let textToAppend = (lines + [""]).joined(separator: "\n")
            let path = url.filePath()
            guard mf.fileExists(atPath: path) else {
                try textToAppend.write(toFile: path, encoding: .utf8)
                return
            }
            try textToAppend.append(toFile: path, encoding: .utf8)
        } catch {
            NSLog("LocalLogger: Unable to save log to disk: \(error)")
        }
    }
}
