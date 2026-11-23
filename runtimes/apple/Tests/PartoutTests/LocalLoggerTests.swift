// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct LocalLoggerTests {
    @Test
    func givenLogger_whenChangingLevel_thenReplacementUsesNewWriteThreshold() {
        let strategy = MockStrategy()
        let previous = LocalLogger(strategy: strategy, url: URL(fileURLWithPath: "unused"),
                                   options: .init(maxLevel: .info, maxSize: 100, maxBufferedLines: 10), mapper: \.message)
        previous.append(.info, message: "retained")
        let extensive = previous.withMaxLevel(.debug)
        extensive.restart(from: previous)
        extensive.append(.debug, message: "details")
        #expect(extensive.currentLog(sinceLast: 60, maxLevel: .debug) == ["retained", "details"])
        let normal = extensive.withMaxLevel(.info)
        normal.restart(from: extensive)
        normal.append(.debug, message: "ignored")
        #expect(normal.currentLog(sinceLast: 60, maxLevel: .debug) == ["retained"])
        normal.save()
        #expect(strategy.currentSize == UInt64("retained\n".utf8.count))
    }

    @Test
    func givenInfoThreshold_whenLoggingDebug_thenDoesNotEvaluateMessage() {
        var builder = PartoutLogger.Builder()
        builder.maxLevel = .info
        let logger = builder.build()
        var evaluations = 0
        func message() -> String {
            evaluations += 1
            return "message"
        }
        logger.log(.global, .runtime, .debug, message())
        #expect(evaluations == 0)
        logger.log(.global, .runtime, .info, message())
        #expect(evaluations == 1)
    }

    @Test
    func givenBoundedHistory_whenBufferFlushes_thenKeepsNewestEntries() {
        let sut = LocalLogger(strategy: MockStrategy(), url: URL(fileURLWithPath: "unused"),
                              options: .init(maxLevel: .info, maxSize: 100, maxBufferedLines: 2), mapper: \.message)
        for message in ["first", "second", "third"] {
            sut.append(.info, message: message)
        }
        #expect(sut.currentLog(sinceLast: 60, maxLevel: .info) == ["second", "third"])
        sut.save()
        #expect(sut.currentLog(sinceLast: 60, maxLevel: .info) == ["second", "third"])
    }

    @Test
    func givenInfoLogger_whenDebugArrives_thenDoesNotBufferOrRotate() {
        let strategy = MockStrategy()
        let sut = LocalLogger(strategy: strategy, url: URL(fileURLWithPath: "unused"),
                              options: .init(maxLevel: .info, maxSize: 100, maxBufferedLines: 0), mapper: \.message)
        sut.append(.debug, message: "ignored")
        sut.save()
        #expect(sut.currentLog(sinceLast: 60, maxLevel: .debug).isEmpty)
        #expect(strategy.moveCount == 0)
        #expect(strategy.currentSize == 0)
    }

    @Test
    func givenHistory_whenFlushingAndReplacing_thenPreservesOnlyAllowedEntries() {
        let url = URL(fileURLWithPath: "unused")
        let previous = LocalLogger(strategy: MockStrategy(), url: url,
                                   options: .init(maxLevel: .debug, maxSize: 100, maxBufferedLines: 3), mapper: \.message)
        previous.append(.info, message: "connected")
        previous.append(.debug, message: "detail")
        previous.save()
        #expect(previous.currentLog(sinceLast: 60, maxLevel: .info) == ["connected"])
        let replacement = LocalLogger(strategy: MockStrategy(), url: url,
                                      options: .init(maxLevel: .info, maxSize: 100, maxBufferedLines: 3), mapper: \.message)
        replacement.restart(from: previous)
        #expect(replacement.currentLog(sinceLast: 60, maxLevel: .debug) == ["connected"])
    }

    @Test
    func givenUnicodeBatch_whenRotating_thenPreservesEveryEntryWithinByteBudget() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.txt")
        let sut = LocalLogger(url: url, options: .init(maxLevel: .info, maxSize: 7, maxBufferedLines: 10), mapper: \.message)
        for message in ["é", "a", "界", "b", "c"] {
            sut.append(.info, message: message)
        }
        sut.save()
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var entries: [String] = []
        for file in files {
            let data = try Data(contentsOf: file)
            #expect(data.count <= 7)
            entries += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        #expect(entries.sorted() == ["é", "a", "界", "b", "c"].sorted())
        #expect(files.count == 3)
        #expect(sut.currentLog(sinceLast: 60, maxLevel: .info).count == 5)
    }

    @Test
    func givenMissingDirectory_whenSaveFails_thenRetriesPendingEntries() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.txt")
        let sut = LocalLogger(url: url, options: .init(maxLevel: .info, maxSize: 100, maxBufferedLines: 10), mapper: \.message)
        sut.append(.info, message: "retained")
        sut.save()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        sut.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "retained\n")
    }

    @Test
    func givenBufferedLogger_whenRestarting_thenTransfersBufferAndStopsPreviousLogger() {
        let options = LocalLogger.Options(maxLevel: .debug, maxSize: 10000, maxBufferedLines: 100)
        let url = URL(fileURLWithPath: "unused")
        let previous = LocalLogger(strategy: MockStrategy(), url: url, options: options, mapper: \.message)
        let replacement = LocalLogger(strategy: MockStrategy(), url: url, options: options, mapper: \.message)
        previous.append(.info, message: "before replacement")

        replacement.restart(from: previous)
        previous.append(.info, message: "stale writer")
        replacement.append(.info, message: "after replacement")

        #expect(previous.currentLog(sinceLast: 60, maxLevel: .debug).isEmpty)
        #expect(replacement.currentLog(sinceLast: 60, maxLevel: .debug) == [
            "before replacement", "after replacement"
        ])
    }

    @Test
    func givenSensitiveLogs_whenReset_thenClearsBufferAndCurrentFile() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let url = directory.appendingPathComponent("app.txt")
        let archive = url.appendingPathExtension("archive")
        try "archived".write(to: archive, atomically: true, encoding: .utf8)
        let sut = LocalLogger(
            url: url,
            options: .init(maxLevel: .debug, maxSize: 10000, maxBufferedLines: 100),
            mapper: \.message
        )
        sut.append(.info, message: "persisted secret")
        sut.save()
        sut.append(.info, message: "buffered secret")

        try sut.reset()

        #expect(sut.currentLog(sinceLast: 60, maxLevel: .debug).isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8).isEmpty)
        #expect(try String(contentsOf: archive, encoding: .utf8) == "archived")
        sut.append(.info, message: "redacted")
        sut.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "redacted\n")
        sut.stop()
        sut.append(.info, message: "late secret")
        sut.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "redacted\n")
    }

    @Test
    func givenLogFiles_whenPurgingExpiredLogs_thenPreservesRecentAndCurrentLogs() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let currentURL = directory.appendingPathComponent("app.txt")
        let expiredURL = currentURL.appendingPathExtension("expired")
        let recentURL = currentURL.appendingPathExtension("recent")
        let maxAge: TimeInterval = 86400
        let files = [
            (currentURL, -3 * maxAge),
            (expiredURL, -2 * maxAge),
            (recentURL, -maxAge / 2)
        ]
        for (url, age) in files {
            try "log\n".write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: age)],
                ofItemAtPath: url.path
            )
        }

        LocalLogger.FileStrategy().purgeLogs(at: currentURL, beyond: maxAge, includingCurrent: false)

        #expect(!fm.fileExists(atPath: expiredURL.path))
        #expect(fm.fileExists(atPath: recentURL.path))
        #expect(fm.fileExists(atPath: currentURL.path))
    }

    @Test
    func givenLogger_whenCurrentLogFits_thenDoesNotRotate() {
        let strategy = MockStrategy()
        let sut = newLogger(strategy: strategy)
        for _ in 0..<2 {
            sut.append(logLevel, message: message)
        }
        #expect(strategy.moveCount == 0)
    }

    @Test
    func givenLogger_whenCurrentLogOverflows_thenRotates() {
        let strategy = MockStrategy()
        let sut = newLogger(strategy: strategy)
        for _ in 0..<3 {
            sut.append(logLevel, message: message)
        }
        #expect(strategy.moveCount == 1)
        #expect(strategy.oldLines == 0)
        #expect(strategy.newLines == 1)
    }
}

private extension LocalLoggerTests {
    var message: String {
        "message"
    }

    var logLevel: DebugLog.Level {
        .debug
    }

    func newLogger(strategy: LocalLogger.Strategy) -> LocalLogger {

        // append newline
        let messageLength = message.count + 1

        // 2 messages at most
        let maxSize = UInt64(2.5 * Double(messageLength))

        // save on each append
        let maxBufferedLines = 0

        return LocalLogger(
            strategy: strategy,
            url: URL(fileURLWithPath: "foobar"),
            options: .init(
                maxLevel: logLevel,
                maxSize: maxSize,
                maxBufferedLines: maxBufferedLines
            ),
            mapper: \.message
        )
    }
}

// MARK: -

private final class MockStrategy: LocalLogger.Strategy {
    var currentSize: UInt64 = 0

    var moveCount = 0

    var newURL: URL?

    var oldLines: Int?

    var newLines: Int?

    func size(of url: URL) -> UInt64 {
        currentSize
    }

    func rotate(url: URL, withLines _: [String]?) throws {
        moveCount += 1
        currentSize = 0
        newURL = url
        oldLines = 0
    }

    func append(lines: [String], to url: URL) throws {
        currentSize += UInt64(lines.reduce(0, {
            $0 + $1.count + 1 // "\n"
        }))
        if url == newURL {
            newLines = lines.count
        } else {
            oldLines = lines.count
        }
    }

    func availableLogs(at url: URL) -> [Date: URL] {
        [:]
    }

    func reset(at url: URL) throws {
        currentSize = 0
    }

    func purgeLogs(at url: URL, beyond maxAge: TimeInterval?, includingCurrent: Bool) {
    }
}
