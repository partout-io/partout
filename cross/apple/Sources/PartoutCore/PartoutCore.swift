// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@_exported import _PartoutPortable_C
@_exported import Foundation

public enum PartoutCore {
    /// The unique identifier of the library.
    public static let identifier = "io.partout"
}

extension LoggerCategory: CaseIterable {
    public static let abi = Self(rawValue: "abi")
    public static let core = Self(rawValue: "core")
    public static let os = Self(rawValue: "os")

    public static let allCases: [LoggerCategory] = [
        .abi,
        .core,
        .os,
    ]
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
