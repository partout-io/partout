// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public enum PartoutErrorCode: Int, Hashable, Codable, Sendable {
    /// No error.
    case success = 0

    // MARK: Generic

    /// Response is cached.
    case cached

    /// Entity not found.
    case notFound

    /// Operation cancelled or unauthorized.
    case operationCancelled

    /// A required object was released prematurely.
    case releasedObject

    /// An exception was raised during a script execution.
    case scriptException

    /// Operation timed out.
    case timeout

    /// Generic failure.
    case unhandled

    // MARK: Profile

    /// Some modules are incompatible (`userInfo` is an array of incompatible ``Module``).
    case incompatibleModules

    /// A module is incomplete (`userInfo` is the incomplete ``ModuleBuilder`` ID).
    case incompleteModule

    /// The profile has no active modules.
    case noActiveModules

    /// The profile has non-final modules that must be resolved to final modules first.
    case nonFinalModules

    /// Missing a required implementation.
    case requiredImplementation

    /// Module type is unexpected
    case unexpectedModuleType

    /// Module content is unknown for the importer.
    case unknownImportedModule

    /// Module handler is unknown.
    @available(*, deprecated, message: "Legacy decoding")
    case unknownModuleHandler

    // MARK: Networking

    /// Authentication failure.
    case authentication

    /// Crypto error.
    case crypto

    /// DNS resolution failure.
    case dnsFailure

    /// No more endpoints available to try.
    case exhaustedEndpoints

    /// File descriptor is not available.
    case fdUnavailable

    /// I/O failure.
    case ioFailure

    /// Link device is not active.
    case linkNotActive

    /// Network changed.
    case networkChanged

    /// Network is unreachable.
    case networkUnreachable

    /// Native sockets could not be configured.
    case socketConfiguration

    /// TUN device is not active.
    case tunNotActive

    /// TUN device is not available for I/O.
    case tunNotAvailable

    // MARK: Serialization

    /// Decoding error.
    case decoding

    /// Encoding error.
    case encoding

    // MARK: Validation

    /// Invalid field.
    case invalidField

    /// Invalid value.
    case invalidValue

    /// Parsing error.
    case parsing

    // MARK: Keychain

    /// Unable to add keychain item.
    case keychainAddItem

    /// Keychain item not found.
    case keychainItemNotFound

    // MARK: OpenVPN

    /// Compression settings mismatch.
    case openVPNCompressionMismatch

    /// Connection failure.
    case openVPNConnectionFailure

    /// No routing configuration.
    case openVPNNoRouting

    /// One-time password is required.
    case openVPNOTPRequired

    /// Passphrase is required.
    case openVPNPassphraseRequired

    /// Authentication can be retried.
    case openVPNRecoverableAuthentication

    /// Server requested shutdown.
    case openVPNServerShutdown

    /// TLS failure.
    case openVPNTLSFailure

    /// Algorithm is unsupported.
    case openVPNUnsupportedAlgorithm

    /// Compression setting is unsupported.
    case openVPNUnsupportedCompression

    /// Option is unsupported.
    case openVPNUnsupportedOption

    // MARK: WireGuard

    /// Configuration has no peers.
    case wireGuardEmptyPeers
}

extension PartoutError {
    public typealias Code = PartoutErrorCode
}

// MARK: - Raw Values

public func == (lhs: Int, rhs: PartoutError.Code) -> Bool {
    PartoutError.Code(rawValue: lhs) == rhs
}

public func == (lhs: PartoutError.Code, rhs: Int) -> Bool {
    rhs == lhs
}

public func == (lhs: Int?, rhs: PartoutError.Code) -> Bool {
    lhs.map { $0 == rhs } ?? false
}

public func == (lhs: PartoutError.Code, rhs: Int?) -> Bool {
    rhs == lhs
}

public func ~= (pattern: PartoutError.Code, value: Int) -> Bool {
    value == pattern
}

public func ~= (pattern: PartoutError.Code, value: Int?) -> Bool {
    value == pattern
}
