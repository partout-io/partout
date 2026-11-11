// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The local logger.
public final class LocalLogger: @unchecked Sendable {

    /// The destination store of the log content.
    public protocol Strategy {
        func size(of url: URL) -> UInt64

        func rotate(url: URL, withLines oldLines: [String]?) throws

        func append(lines: [String], to url: URL) throws

        func reset(at url: URL) throws

        func availableLogs(at url: URL) -> [Date: URL]

        func purgeLogs(at url: URL, beyond maxAge: TimeInterval?, includingCurrent: Bool)
    }

    /// The options to configure the local logger.
    public struct Options: Codable, Sendable {
        public let maxLevel: DebugLog.Level

        public let maxSize: UInt64

        /// Pending-write threshold and maximum retained live-history entries (at least one).
        public let maxBufferedLines: Int

        /// Maximum age of archived files and retained live-history entries.
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

    private let mapper: @Sendable (DebugLog.Line) -> String

    private var lines: [DebugLog.Line]

    private var history: [DebugLog.Line] = []

    private var isStopped = false

    init(
        strategy: Strategy = FileStrategy(),
        url: URL,
        options: Options,
        mapper: @escaping @Sendable (DebugLog.Line) -> String
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

    func withMaxLevel(_ maxLevel: DebugLog.Level) -> LocalLogger {
        LocalLogger(
            strategy: strategy,
            url: currentURL,
            options: .init(
                maxLevel: maxLevel,
                maxSize: options.maxSize,
                maxBufferedLines: options.maxBufferedLines,
                maxAge: options.maxAge
            ),
            mapper: mapper
        )
    }

    func restart(from logger: LocalLogger) {
        let previous = logger.stop()
        queue.sync {
            lines = previous.pending.filter { $0.level <= options.maxLevel }
            history = previous.history.filter { $0.level <= options.maxLevel }
            trimHistory()
        }
    }

    func reset() throws {
        try queue.sync {
            lines.removeAll()
            history.removeAll()
            try strategy.reset(at: currentURL)
        }
    }

    @discardableResult
    func stop() -> (pending: [DebugLog.Line], history: [DebugLog.Line]) {
        queue.sync {
            isStopped = true
            defer {
                lines.removeAll()
                history.removeAll()
            }
            return (lines, history)
        }
    }

    func append(_ level: DebugLog.Level, message: String) {
        queue.sync {
            guard !isStopped, level <= options.maxLevel else { return }
            let line = DebugLog.Line(
                timestamp: Date(),
                level: level,
                message: message
            )
            lines.append(line)
            history.append(line)
            trimHistory()
            if lines.count > options.maxBufferedLines {
                unsafeSave()
            }
        }
    }

    func currentLines(sinceLast: TimeInterval, maxLevel: DebugLog.Level) -> [DebugLog.Line] {
        queue.sync {
            let since = Date(timeIntervalSinceNow: -sinceLast)
            trimHistory()
            return history
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

    func availableLogs() -> [Date: URL] {
        strategy.availableLogs(at: currentURL)
    }

    func purgeLogs(beyond maxAge: TimeInterval, includingCurrent: Bool) {
        strategy.purgeLogs(at: currentURL, beyond: maxAge, includingCurrent: includingCurrent)
    }
}

extension LocalLogger.Strategy {
    public func purgeLogs(at url: URL) {
        purgeLogs(at: url, beyond: nil, includingCurrent: true)
    }
}

// MARK: - Private API

extension LocalLogger {
    // Live history is independent of pending writes and bounded by count and age.
    private func trimHistory() {
        if let maxAge = options.maxAge {
            let since = Date(timeIntervalSinceNow: -maxAge)
            history.removeAll { $0.timestamp < since }
        }
        let limit = max(1, options.maxBufferedLines)
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }

    func unsafeSave() {
        guard !lines.isEmpty else {
            return
        }

        do {
            var size = strategy.size(of: currentURL)
            while !lines.isEmpty {
                var batch: [String] = []
                var nextSize = size
                for line in lines {
                    let text = mapper(line)
                    let byteCount = UInt64(text.utf8.count) + 1
                    // Keep an oversized entry intact in its own file.
                    if nextSize > 0 && (nextSize >= options.maxSize || byteCount > options.maxSize - nextSize) {
                        break
                    }
                    batch.append(text)
                    nextSize += byteCount
                }
                if batch.isEmpty {
                    try strategy.rotate(url: currentURL, withLines: nil)
                    size = 0
                    continue
                }
                try strategy.append(lines: batch, to: currentURL)
                lines.removeFirst(batch.count)
                size = nextSize
            }
        } catch {
            NSLog("LocalLogger: Unable to save log to disk: \(error)")
        }

        if let maxAge = options.maxAge {
            strategy.purgeLogs(at: currentURL, beyond: maxAge, includingCurrent: false)
        }
    }
}
