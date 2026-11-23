// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Container of all OpenVPN entities.
///
/// Compatibility namespace for OpenVPN model types generated from OpenAPI.
public enum OpenVPN {}

/// Container of all WireGuard entities.
///
/// Compatibility namespace for WireGuard model types generated from OpenAPI.
public enum WireGuard {}

public typealias OpenVPNCryptoContainer = OpenVPN.CryptoContainer
public typealias OpenVPNObfuscationMethod = OpenVPN.ObfuscationMethod
public typealias WireGuardKey = WireGuard.Key

public typealias DNSModuleProtocolType = DNSModule.ProtocolType
public typealias ModelUInt16 = UInt16
public typealias ModelUInt32 = UInt32
public typealias ModelUInt64 = UInt64

extension DNSModule {
    public typealias DomainPolicy = DNSModuleDomainPolicy
}

extension DNSModule.ProtocolType {
    public typealias Cleartext = DNSModuleProtocolTypeCleartext
    public typealias HTTPS = DNSModuleProtocolTypeHttps
    public typealias TLS = DNSModuleProtocolTypeTls
}

extension OnDemandModule {
    public typealias OtherNetwork = OnDemandModuleOtherNetwork
    public typealias Policy = OnDemandModulePolicy
}

extension OpenVPN {
    public typealias Cipher = OpenVPNCipher
    public typealias CompressionAlgorithm = OpenVPNCompressionAlgorithm
    public typealias CompressionFraming = OpenVPNCompressionFraming
    public typealias Configuration = OpenVPNConfiguration
    public typealias Credentials = OpenVPNCredentials
    public typealias Digest = OpenVPNDigest
    public typealias PullMask = OpenVPNPullMask
    public typealias RoutingPolicy = OpenVPNRoutingPolicy
    public typealias StaticKey = OpenVPNStaticKey
    public typealias TLSWrap = OpenVPNTLSWrap
}

extension OpenVPN.Credentials {
    public typealias OTPMethod = OpenVPNCredentialsOTPMethod
}

extension OpenVPN.ObfuscationMethod {
    public typealias Obfuscate = OpenVPNObfuscationMethodObfuscate
    public typealias Reverse = OpenVPNObfuscationMethodReverse
    public typealias XORMask = OpenVPNObfuscationMethodXormask
    public typealias XORPtrPos = OpenVPNObfuscationMethodXorptrpos
}

extension OpenVPN.StaticKey {
    public typealias Direction = OpenVPNStaticKeyDirection
}

extension OpenVPN.TLSWrap {
    public typealias Strategy = OpenVPNTLSWrapStrategy
}

extension PartoutError {
    public typealias Code = PartoutErrorCode
}

extension TunnelSnapshot {
    public typealias Environment = TunnelSnapshotEnvironment
}

extension WireGuard {
    public typealias Configuration = WireGuardConfiguration
    public typealias LocalInterface = WireGuardLocalInterface
    public typealias RemoteInterface = WireGuardRemoteInterface
}
