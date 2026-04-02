// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

// MARK: "Macros"

func setUpLogging() {
    var logger = PartoutLogger.Builder()
    logger.setDestination(SimpleLogDestination(tag: nil), for: [.core])
    PartoutLogger.register(logger.build())
}

extension Error {
    public var localizedComment: Comment? {
        Comment(stringLiteral: localizedDescription)
    }
}
