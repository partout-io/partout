// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// Generated from scripts/openapi.yaml. Do not edit by hand.


public enum PartoutErrorCode: String, Hashable, Codable, Sendable {
    case cached
    case notFound
    case operationCancelled
    case releasedObject
    case scriptException
    case timeout
    case unhandled
    case incompatibleModules
    case incompleteModule
    case noActiveModules
    case nonFinalModules
    case requiredImplementation
    case unexpectedModuleType
    case unknownImportedModule
    case unknownModuleHandler
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
    case decoding
    case encoding
    case invalidField
    case invalidValue
    case parsing
    case keychainAddItem
    case keychainItemNotFound
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
    case wireGuardEmptyPeers = "WireGuard.emptyPeers"
}

public struct ABIErrorPayload: Codable, Sendable {
    public let code: PartoutErrorCode
    public let userInfo: JSON?

    public init(code: PartoutErrorCode, userInfo: JSON?) {
        self.code = code
        self.userInfo = userInfo
    }
}
