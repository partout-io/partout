// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public enum PartoutErrorCode: String, Hashable, Codable, Sendable {

    // MARK: Generic

    case cached
    case notFound
    case operationCancelled
    case releasedObject
    case scriptException
    case timeout
    case unhandled

    // MARK: Profile

    case incompatibleModules
    case incompleteModule
    case noActiveModules
    case nonFinalModules
    case requiredImplementation
    case unexpectedModuleType
    case unknownImportedModule
    @available(*, deprecated, message: "Legacy decoding")
    case unknownModuleHandler

    // MARK: Networking

    case authentication
    case crypto
    case dnsFailure
    case exhaustedEndpoints
    case fdUnavailable
    case ioFailure
    case linkNotActive
    case networkChanged
    case networkUnreachable
    case socketConfiguration
    case tunNotActive
    case tunNotAvailable

    // MARK: Serialization

    case decoding
    case encoding

    // MARK: Validation

    case invalidField
    case invalidValue
    case parsing

    // MARK: Keychain

    case keychainAddItem
    case keychainItemNotFound

    // MARK: OpenVPN

    case openVPNCompressionMismatch = "OpenVPN.compressionMismatch"
    case openVPNConnectionFailure = "OpenVPN.connectionFailure"
    case openVPNNoRouting = "OpenVPN.noRouting"
    case openVPNOTPRequired = "OpenVPN.otpRequired"
    case openVPNPassphraseRequired = "OpenVPN.passphraseRequired"
    case openVPNRecoverableAuthentication = "OpenVPN.recoverableAuthentication"
    case openVPNServerShutdown = "OpenVPN.serverShutdown"
    case openVPNTLSFailure = "OpenVPN.tlsFailure"
    case openVPNUnsupportedAlgorithm = "OpenVPN.unsupportedAlgorithm"
    case openVPNUnsupportedCompression = "OpenVPN.unsupportedCompression"
    case openVPNUnsupportedOption = "OpenVPN.unsupportedOption"

    // MARK: WireGuard

    case wireGuardEmptyPeers = "WireGuard.emptyPeers"
}

extension PartoutError {
    public typealias Code = PartoutErrorCode
}

// MARK: - Raw Values

public func == (lhs: String, rhs: PartoutError.Code) -> Bool {
    PartoutError.Code(rawValue: lhs) == rhs
}

public func == (lhs: PartoutError.Code, rhs: String) -> Bool {
    rhs == lhs
}

public func == (lhs: String?, rhs: PartoutError.Code) -> Bool {
    lhs.map { $0 == rhs } ?? false
}

public func == (lhs: PartoutError.Code, rhs: String?) -> Bool {
    rhs == lhs
}

public func ~= (pattern: PartoutError.Code, value: String) -> Bool {
    value == pattern
}

public func ~= (pattern: PartoutError.Code, value: String?) -> Bool {
    value == pattern
}
