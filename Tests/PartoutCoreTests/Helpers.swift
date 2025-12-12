// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

// MARK: "Macros"

func setUpLogging() {
    var logger = PartoutLogger.Builder()
    logger.setDestination(SimpleLogDestination(), for: [.core])
    PartoutLogger.register(logger.build())
}

func expectNoThrow<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
    } catch {
        #expect(Bool(false), "\(message()) at \(file):\(line) (error: \(error.localizedDescription))")
    }
}

extension Error {
    public var localizedComment: Comment? {
        Comment(stringLiteral: localizedDescription)
    }
}
