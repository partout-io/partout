// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE
@_exported import MiniFoundation
#endif

extension LoggerCategory {
    public static let abi = Self(rawValue: "abi")
    public static let core = Self(rawValue: "core")
}

// MARK: Profile

extension PartoutError {
    public static func incompatibleModules(module: Module, otherModule: Module) -> Self {
        Self(.incompatibleModules, [module, otherModule])
    }

    @available(*, deprecated, message: "Legacy decoding")
    public static func unknownModuleHandler(moduleType: ModuleType) -> Self {
        Self(.unknownModuleHandler, moduleType.debugDescription)
    }
}

// MARK: Validation

extension PartoutError {
    public struct ModuleField: Equatable, Sendable {
        public let key: String

        public init(_ key: String) {
            self.key = key
        }
    }

    public static func invalidField(_ key: ModuleField) -> Self {
        Self(.invalidField, key)
    }
}

// MARK: Generic

extension PartoutError {
    public static func unhandled(reason: Error) -> Self {
        Self(.unhandled, reason)
    }
}
