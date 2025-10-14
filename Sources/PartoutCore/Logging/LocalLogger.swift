// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// The local logger.
public final class LocalLogger: @unchecked Sendable {

    /// The destination store of the log content.
    public protocol Strategy {
        func size(of url: URL) -> UInt64

        func rotate(url: URL, withLines oldLines: [String]?) throws

        func append(lines: [String], to url: URL) throws

        func availableLogs(at url: URL) -> [Date: URL]

        func purgeLogs(at url: URL, beyond maxAge: TimeInterval, includingCurrent: Bool)
    }

    /// The options to configure the local logger.
    public struct Options: Codable, Sendable {
        public let maxLevel: DebugLog.Level

        public let maxSize: UInt64

        public let maxBufferedLines: Int

        public let maxAge: TimeInterval?

        public init(
            maxLevel: DebugLog.Level,
            maxSize: UInt64,
            maxBufferedLines: Int,
            maxAge: TimeInterval? = nil
        ) {
            self.maxLevel = maxLevel
            self.maxSize = maxSize
            self.maxBufferedLines = maxBufferedLines
            self.maxAge = maxAge
        }
    }

    private let queue: DispatchQueue

    private let strategy: Strategy

    private let currentURL: URL

    private let options: Options

    private let mapper: (DebugLog.Line) -> String

    private var lines: [DebugLog.Line]

    init(
        strategy: Strategy = FileStrategy(),
        url: URL,
        options: Options,
        mapper: @escaping (DebugLog.Line) -> String
    ) {
        queue = DispatchQueue(label: "LocalLogger")
        self.strategy = strategy
        currentURL = url
        self.options = options
        self.mapper = mapper
        lines = []
    }

    public var url: URL {
        currentURL
    }

    func append(_ level: DebugLog.Level, message: String) {
        queue.sync {
            lines.append(DebugLog.Line(
                timestamp: Date(),
                level: level,
                message: message
            ))
            if lines.count > options.maxBufferedLines {
                unsafeSave()
            }
        }
    }

    func currentLines(sinceLast: TimeInterval, maxLevel: DebugLog.Level) -> [DebugLog.Line] {
        queue.sync {
            let since = Date(timeIntervalSinceNow: -sinceLast)
            return lines
                .filter {
                    $0.timestamp >= since && $0.level <= maxLevel
                }
        }
    }

    func save() {
        queue.sync {
            unsafeSave()
        }
    }

    func availableLogs() -> [Date: URL] {
        strategy.availableLogs(at: currentURL)
    }

    func purgeLogs(beyond maxAge: TimeInterval, includingCurrent: Bool) {
        strategy.purgeLogs(at: currentURL, beyond: maxAge, includingCurrent: includingCurrent)
    }
}

extension LocalLogger.Strategy {
    public func purgeLogs(at url: URL) {
        purgeLogs(at: url, beyond: -.infinity, includingCurrent: true)
    }
}

// MARK: - Private API

extension LocalLogger {
    func unsafeSave() {
        guard !lines.isEmpty else {
            return
        }

        // current size
        let size = strategy.size(of: currentURL)

        // split lines across current and next log
        var linesToAppend = lines
            .filter {
                $0.level <= options.maxLevel
            }
            .map(mapper)

        var nextSize = size
        var indexOfLastLine: Int?
        for pair in linesToAppend.enumerated() {
            nextSize += UInt64(pair.element.count) + 1 // "\n"
            if nextSize > options.maxSize {
                break
            }
            indexOfLastLine = pair.offset
        }

        do {
            // current log can fit new lines
            if indexOfLastLine == linesToAppend.count - 1 {
                try strategy.append(lines: linesToAppend, to: currentURL)
            } else {

                // append old lines to current log
                if let indexOfLastLine {
                    let oldLines = Array(linesToAppend.prefix(indexOfLastLine))
                    try strategy.rotate(url: currentURL, withLines: oldLines)
                } else {
                    try strategy.rotate(url: currentURL, withLines: nil)
                }

                // flush remaining lines to new log
                if let indexOfLastLine {
                    linesToAppend.removeSubrange(0..<indexOfLastLine)
                }
                try strategy.append(lines: linesToAppend, to: currentURL)
            }

            // reset buffer
            lines.removeAll()
        } catch {
            NSLog("LocalLogger: Unable to save log to disk: \(error)")
        }

        if let maxAge = options.maxAge {
            strategy.purgeLogs(at: currentURL, beyond: maxAge, includingCurrent: false)
        }
    }
}
