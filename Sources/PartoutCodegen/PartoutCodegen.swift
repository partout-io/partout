// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public enum PartoutCodegen {
    public static let paths: [String] = [
        "PartoutCore/Connection",
        "PartoutCore/IP",
        "PartoutCore/Modules",
        "PartoutCore/Profile",
        "PartoutOpenVPN",
        "PartoutWireGuard"
    ]

    public static let entities: [String] = [
        "Address",
//        "Address.Family",
        "Endpoint",
        "EndpointProtocol",
        "ExtendedEndpoint",
        "IPSettings",
        "IPSocketType",
        "ModuleType",
//        "Profile.ID",
        "ProfileBehavior",
        "Route",
//        "SecureData",
        "SocketType",
        "Subnet",
        //
        "DNSModule",
        "DNSModule.ProtocolType",
        "DNSProtocol",
        "HTTPProxyModule",
        "IPModule",
        "OnDemandModule",
        "OnDemandModule.OtherNetwork",
        "OnDemandModule.Policy",
        //
        "TaggedModule",
        "TunnelRemoteInfo",
        //
        "OpenVPNModule",
        "OpenVPN.Cipher",
        "OpenVPN.CompressionAlgorithm",
        "OpenVPN.CompressionFraming",
        "OpenVPN.Configuration",
        "OpenVPN.Credentials",
        "OpenVPN.Credentials.OTPMethod",
        "OpenVPN.CryptoContainer",
        "OpenVPN.Digest",
        "OpenVPN.ObfuscationMethod",
        "OpenVPN.PullMask",
        "OpenVPN.RoutingPolicy",
        "OpenVPN.StaticKey",
        "OpenVPN.StaticKey.Direction",
        "OpenVPN.TLSWrap",
        "OpenVPN.TLSWrap.Strategy",
        //
        "WireGuardModule",
        "WireGuard.Configuration",
        "WireGuard.Key",
        "WireGuard.LocalInterface",
        "WireGuard.RemoteInterface"
    ]
}
