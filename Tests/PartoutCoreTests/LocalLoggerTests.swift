// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct LocalLoggerTests {
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

    func purgeLogs(at url: URL, beyond maxAge: TimeInterval?, includingCurrent: Bool) {
    }
}
