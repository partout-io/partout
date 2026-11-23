// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Formats modules and builders for logging.
public struct LoggableModule {
    private let summary: String
    private let detailedDescription: () -> String

    public init(_ ctx: PartoutLoggerContext, _ module: Module) {
        summary = "\(module.moduleType):\(module.id)"
        detailedDescription = {
            if let sensitive = module as? SensitiveDebugStringConvertible {
                return sensitive.debugDescription(withSensitiveData: true)
            }
            if let encodable = module as? Encodable {
                return encodable.asJSON(ctx, withSensitiveData: true) ?? PartoutLogger.malformedValue
            }
            return module.moduleType.debugDescription
        }
    }

    public init(_ builder: any ModuleBuilder) {
        summary = "\(builder.moduleType):\(builder.id)"
        detailedDescription = { String(reflecting: builder) }
    }
}

extension LoggableModule: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? detailedDescription() : summary
    }
}
