// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE
@_exported import MiniFoundation
#endif

extension LoggerCategory {
    public static let core = Self(rawValue: "core")
}

// MARK: Generic

extension PartoutError.Code {

    /// Response is cached.
    public static let cached = Self("cached")

    /// Entity not found.
    public static let notFound = Self("notFound")

    /// Operation cancelled or unauthorized.
    public static let operationCancelled = Self("operationCancelled")

    /// A required object was released prematurely.
    public static let releasedObject = Self("releasedObject")

    /// An exception was raised during a script execution.
    public static let scriptException = Self("scriptException")

    /// Operation timed out.
    public static let timeout = Self("timeout")

    /// Generic failure.
    public static let unhandled = Self("unhandled")
}

// MARK: Profile

extension PartoutError.Code {

    /// Some modules are incompatible (`userInfo` is an array of incompatible ``Module``).
    public static let incompatibleModules = Self("incompatibleModules")

    /// A module is incomplete (`userInfo` is the incomplete ``ModuleBuilder`` ID).
    public static let incompleteModule = Self("incompleteModule")

    /// The profile has no active modules.
    public static let noActiveModules = Self("noActiveModules")

    /// The profile has non-final modules that must be resolved to final modules first.
    public static let nonFinalModules = Self("nonFinalModules")

    /// A handler with the same ID was already registered.
    public static let registeredModuleHandler = Self("registeredModuleHandler")

    /// Missing a required implementation.
    public static let requiredImplementation = Self("requiredImplementation")

    /// Module content is unknown for the importer.
    public static let unknownImportedModule = Self("unknownImportedModule")

    /// Module handler is unknown.
    public static let unknownModuleHandler = Self("unknownModuleHandler")
}

extension PartoutError {
    public static func incompatibleModules(module: Module, otherModule: Module) -> Self {
        Self(.incompatibleModules, [module, otherModule])
    }

    public static func unknownModuleHandler(moduleType: ModuleType) -> Self {
        Self(.unknownModuleHandler, moduleType.debugDescription)
    }
}

// MARK: Networking

extension PartoutError.Code {

    /// Authentication failure.
    public static let authentication = Self("authentication")

    /// Crypto error.
    public static let crypto = Self("crypto")

    /// DNS resolution failure.
    public static let dnsFailure = Self("dnsFailure")

    /// No more endpoints available to try.
    public static let exhaustedEndpoints = Self("exhaustedEndpoints")

    /// Link could not be activated.
    public static let linkNotActive = Self("linkNotActive")

    /// Link I/O failure.
    public static let linkFailure = Self("linkFailure")

    /// Network changed.
    public static let networkChanged = Self("networkChanged")

    /// Network is unreachable.
    public static let networkUnreachable = Self("networkUnreachable")
}

// MARK: Serialization

extension PartoutError.Code {

    /// Decoding error.
    public static let decoding = Self("decoding")

    /// Encoding error.
    public static let encoding = Self("encoding")
}

// MARK: Validation

extension PartoutError.Code {

    /// Invalid field.
    public static let invalidFields = Self("invalidFields")

    /// Parsing error.
    public static let parsing = Self("parsing")
}

extension PartoutError {
    public static func invalidFields(_ fields: [String: String?]) -> Self {
        Self(.invalidFields, fields)
    }
}

// MARK: Keychain

extension PartoutError.Code {

    /// Unable to add keychain item.
    public static let keychainAddItem = Self("keychainAddItem")

    /// Keychain item not found.
    public static let keychainItemNotFound = Self("keychainItemNotFound")
}

extension PartoutError {
    public static func unhandled(reason: Error) -> Self {
        Self(.unhandled, reason)
    }
}
