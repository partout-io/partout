// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension LocalLogger {
    public final class FileStrategy: LocalLogger.Strategy {
        public init() {
        }

        public func size(of url: URL) -> UInt64 {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                return attrs[.size] as? UInt64 ?? 0
            } catch {
                NSLog("LocalLogger: Unable to read current log size: \(error)")
                return 0
            }
        }

        public func rotate(url: URL, withLines oldLines: [String]?) throws {
            let suffix = Int(Date().timeIntervalSince1970).description
            let rotatedURL = url.appendingPathExtension(suffix)

            try FileManager.default.moveItem(at: url, to: rotatedURL)
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
                let contents = try FileManager.default.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: nil
                )
                return try contents.reduce(into: [:]) { found, item in
                    let filename = item.lastPathComponent
                    guard filename.hasPrefix(prefix) else {
                        return
                    }
                    let attrs = try FileManager.default.attributesOfItem(atPath: item.path)
                    guard let mdate = attrs[.modificationDate] as? Date else {
                        return
                    }
                    found[mdate] = item
                }
            } catch {
                return [:]
            }
        }

        public func purgeLogs(at url: URL, beyond maxAge: TimeInterval, includingCurrent: Bool) {
            let logs = availableLogs(at: url)
            let minDate = Date().addingTimeInterval(-maxAge)
            logs.forEach { date, logURL in
                guard includingCurrent || logURL != url else { // skip current log
                    return
                }
                guard date >= minDate else {
                    try? FileManager.default.removeItem(at: logURL)
                    return
                }
            }
        }
    }
}

private extension LocalLogger.FileStrategy {
    func write(lines: [String], to url: URL) throws {
        do {
            let textToAppend = (lines + [""]).joined(separator: "\n")
            guard FileManager.default.fileExists(atPath: url.path) else {
                try textToAppend.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            let file = try FileHandle(forUpdating: url)
            try file.seekToEnd()
            if let data = textToAppend.data(using: .utf8) {
                try file.write(contentsOf: data)
            }
        } catch {
            NSLog("LocalLogger: Unable to save log to disk: \(error)")
        }
    }
}
