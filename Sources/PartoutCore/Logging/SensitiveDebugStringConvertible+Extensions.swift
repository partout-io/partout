// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension SensitiveDebugStringConvertible {
    public func asSensitiveBytes(_ ctx: PartoutLoggerContext) -> String {
        debugDescription(withSensitiveData: ctx.logger.logsRawBytes)
    }

    public func asSensitiveAddress(_ ctx: PartoutLoggerContext) -> String {
        debugDescription(withSensitiveData: ctx.logger.logsAddresses)
    }
}
