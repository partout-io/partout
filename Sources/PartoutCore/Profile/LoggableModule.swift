// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Facilitates module logging.
public struct LoggableModule {
    private let ctx: PartoutLoggerContext

    private let module: Module

    public init(_ ctx: PartoutLoggerContext, _ module: Module) {
        self.ctx = ctx
        self.module = module
    }
}

extension LoggableModule: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        if let sensitive = module as? SensitiveDebugStringConvertible {
            return sensitive.debugDescription(withSensitiveData: withSensitiveData)
        } else if let encodable = module as? Encodable {
            return encodable.asJSON(ctx, withSensitiveData: withSensitiveData) ?? JSONEncoder.malformedValue
        } else {
            return module.moduleHandler.id.debugDescription
        }
    }
}
