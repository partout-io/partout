// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Dispatch

/// The local logger.
public final class LocalLogger: @unchecked Sendable {

    /// The destination store of the log content.
    public protocol Strategy {
        func size(of path: String) -> UInt64

        func rotate(path: String, withLines oldLines: [String]?) throws

        func append(lines: [String], to path: String) throws

        func availableLogs(at path: String) -> [Date: String]

        func purgeLogs(at path: String, beyond maxAge: TimeInterval?, includingCurrent: Bool)
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

    private let currentPath: String

    private let options: Options

    private let mapper: (DebugLog.Line) -> String

    private var lines: [DebugLog.Line]

    init(
        strategy: Strategy = FileStrategy(),
        path: String,
        options: Options,
        mapper: @escaping (DebugLog.Line) -> String
    ) {
        queue = DispatchQueue(label: "LocalLogger")
        self.strategy = strategy
        currentPath = path
        self.options = options
        self.mapper = mapper
        lines = []
    }

    public var path: String {
        currentPath
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

    func currentLog(sinceLast: TimeInterval, maxLevel: DebugLog.Level) -> [String] {
        currentLines(sinceLast: sinceLast, maxLevel: maxLevel).map(mapper)
    }

    func save() {
        queue.sync {
            unsafeSave()
        }
    }

    func availableLogs() -> [Date: String] {
        strategy.availableLogs(at: currentPath)
    }

    func purgeLogs(beyond maxAge: TimeInterval, includingCurrent: Bool) {
        strategy.purgeLogs(at: currentPath, beyond: maxAge, includingCurrent: includingCurrent)
    }
}

extension LocalLogger.Strategy {
    public func purgeLogs(at url: String) {
        purgeLogs(at: url, beyond: nil, includingCurrent: true)
    }
}

// MARK: - Private API

extension LocalLogger {
    func unsafeSave() {
        guard !lines.isEmpty else {
            return
        }

        // current size
        let size = strategy.size(of: currentPath)

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
                try strategy.append(lines: linesToAppend, to: currentPath)
            } else {

                // append old lines to current log
                if let indexOfLastLine {
                    let oldLines = Array(linesToAppend.prefix(indexOfLastLine))
                    try strategy.rotate(path: currentPath, withLines: oldLines)
                } else {
                    try strategy.rotate(path: currentPath, withLines: nil)
                }

                // flush remaining lines to new log
                if let indexOfLastLine {
                    linesToAppend.removeSubrange(0..<indexOfLastLine)
                }
                try strategy.append(lines: linesToAppend, to: currentPath)
            }

            // reset buffer
            lines.removeAll()
        } catch {
            NSLog("LocalLogger: Unable to save log to disk: \(error)")
        }

        if let maxAge = options.maxAge {
            strategy.purgeLogs(at: currentPath, beyond: maxAge, includingCurrent: false)
        }
    }
}
