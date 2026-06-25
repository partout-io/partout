// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Compatibility namespace for OpenVPN model types generated from OpenAPI.
public enum OpenVPN {}

/// Compatibility namespace for WireGuard model types generated from OpenAPI.
public enum WireGuard {}

public typealias Address = String
public typealias Endpoint = String
public typealias EndpointProtocol = String
public typealias ExtendedEndpoint = String
public typealias Subnet = String

public typealias OpenVPNCryptoContainer = OpenVPN.CryptoContainer

extension DNSModule {
    public typealias DomainPolicy = DNSModuleDomainPolicy
    public typealias ProtocolType = DNSModuleProtocolType
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
    public typealias ObfuscationMethod = OpenVPNObfuscationMethod
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

extension TaggedModule {
    public typealias Custom = TaggedModuleCustom
    public typealias DNS = TaggedModuleDNS
    public typealias HTTPProxy = TaggedModuleHTTPProxy
    public typealias IP = TaggedModuleIP
    public typealias OnDemand = TaggedModuleOnDemand
    public typealias OpenVPN = TaggedModuleOpenVPN
    public typealias WireGuard = TaggedModuleWireGuard
}

extension TunnelSnapshot {
    public typealias Environment = TunnelSnapshotEnvironment
}

extension WireGuard {
    public typealias Configuration = WireGuardConfiguration
    public typealias Key = String
    public typealias LocalInterface = WireGuardLocalInterface
    public typealias RemoteInterface = WireGuardRemoteInterface
}
