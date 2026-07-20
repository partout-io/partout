// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const gen = @import("api_generated.zig");
const extensions = @import("api_extensions.zig");
const manual = @import("api_manual.zig");
const util = @import("util.zig");
const uuid = @import("uuid.zig");

pub const profile_version: i32 = 3;

pub const ABIErrorPayload = gen.ABIErrorPayload;
pub const Address = manual.Address;
pub const ConnectionStatus = gen.ConnectionStatus;
pub const DataCount = gen.DataCount;
pub const DNSModule = gen.DNSModule;
pub const DNSModuleDomainPolicy = gen.DNSModuleDomainPolicy;
pub const DNSModuleProtocolType = gen.DNSModuleProtocolType;
pub const DNSModuleProtocolTypeCleartext = gen.DNSModuleProtocolTypeCleartext;
pub const DNSModuleProtocolTypeHttps = gen.DNSModuleProtocolTypeHttps;
pub const DNSModuleProtocolTypeTls = gen.DNSModuleProtocolTypeTls;
pub const DNSProtocol = gen.DNSProtocol;
pub const DecodeError = gen.DecodeError;
pub const EncodeError = gen.EncodeError;
pub const Endpoint = manual.Endpoint;
pub const EndpointProtocol = manual.EndpointProtocol;
pub const ExtendedEndpoint = manual.ExtendedEndpoint;
pub const HTTPProxyModule = gen.HTTPProxyModule;
pub const IPModule = gen.IPModule;
pub const IPSettings = gen.IPSettings;
pub const IPSocketType = gen.IPSocketType;
pub const JsonErrorInfo = gen.JsonErrorInfo;
pub const JSONValue = gen.JSONValue;
pub const ModuleType = gen.ModuleType;
pub const OnDemandModule = gen.OnDemandModule;
pub const OnDemandModuleOtherNetwork = gen.OnDemandModuleOtherNetwork;
pub const OnDemandModulePolicy = gen.OnDemandModulePolicy;
pub const OpenVPNCipher = gen.OpenVPNCipher;
pub const OpenVPNCompressionAlgorithm = gen.OpenVPNCompressionAlgorithm;
pub const OpenVPNCompressionFraming = gen.OpenVPNCompressionFraming;
pub const OpenVPNConfiguration = gen.OpenVPNConfiguration;
pub const OpenVPNCredentials = gen.OpenVPNCredentials;
pub const OpenVPNCredentialsOTPMethod = gen.OpenVPNCredentialsOTPMethod;
pub const OpenVPNCryptoContainer = manual.OpenVPNCryptoContainer;
pub const OpenVPNDigest = gen.OpenVPNDigest;
pub const OpenVPNModule = gen.OpenVPNModule;
pub const OpenVPNObfuscationMethod = gen.OpenVPNObfuscationMethod;
pub const OpenVPNObfuscationMethodObfuscate = gen.OpenVPNObfuscationMethodObfuscate;
pub const OpenVPNObfuscationMethodReverse = gen.OpenVPNObfuscationMethodReverse;
pub const OpenVPNObfuscationMethodXormask = gen.OpenVPNObfuscationMethodXormask;
pub const OpenVPNObfuscationMethodXorptrpos = gen.OpenVPNObfuscationMethodXorptrpos;
pub const OpenVPNPullMask = gen.OpenVPNPullMask;
pub const OpenVPNRoutingPolicy = gen.OpenVPNRoutingPolicy;
pub const OpenVPNStaticKey = gen.OpenVPNStaticKey;
pub const OpenVPNStaticKeyDirection = gen.OpenVPNStaticKeyDirection;
pub const OpenVPNTLSWrap = gen.OpenVPNTLSWrap;
pub const OpenVPNTLSWrapStrategy = gen.OpenVPNTLSWrapStrategy;
pub const ParseErrorInfo = gen.ParseErrorInfo;
pub const PartoutErrorCode = gen.PartoutErrorCode;
pub const Profile = gen.Profile;
pub const ProfileBehavior = gen.ProfileBehavior;
pub const Route = gen.Route;
pub const SecureData = manual.SecureData;
pub const SocketType = gen.SocketType;
pub const Subnet = manual.Subnet;
pub const TaggedModule = gen.TaggedModule;
pub const TaggedModuleDNS = gen.TaggedModuleDNS;
pub const TaggedModuleHTTPProxy = gen.TaggedModuleHTTPProxy;
pub const TaggedModuleIP = gen.TaggedModuleIP;
pub const TaggedModuleOnDemand = gen.TaggedModuleOnDemand;
pub const TaggedModuleOpenVPN = gen.TaggedModuleOpenVPN;
pub const TaggedModuleWireGuard = gen.TaggedModuleWireGuard;
pub const TunnelRemoteInfoWrapper = gen.TunnelRemoteInfoWrapper;
pub const TunnelSnapshot = gen.TunnelSnapshot;
pub const TunnelSnapshotEnvironment = gen.TunnelSnapshotEnvironment;
pub const TunnelStatus = gen.TunnelStatus;
pub const UUID = uuid.UUID;
pub const WireGuardConfiguration = gen.WireGuardConfiguration;
pub const WireGuardKey = manual.WireGuardKey;
pub const WireGuardLocalInterface = gen.WireGuardLocalInterface;
pub const WireGuardModule = gen.WireGuardModule;
pub const WireGuardRemoteInterface = gen.WireGuardRemoteInterface;

pub const encodeModule = extensions.encodeModule;
pub const encodeModuleZ = extensions.encodeModuleZ;
pub const encodeProfile = extensions.encodeProfile;
pub const encodeProfileZ = extensions.encodeProfileZ;
pub const findActiveConnectionModule = extensions.findActiveConnectionModule;
pub const hasConnection = extensions.hasConnection;
pub const isActiveProfileModule = extensions.isActiveProfileModule;
pub const logDecodedProfile = extensions.logDecodedProfile;
pub const moduleId = extensions.moduleId;
pub const moduleType = extensions.moduleType;
pub const parseModule = extensions.parseModule;
pub const typeBuildsConnection = extensions.typeBuildsConnection;

// ZIGME: Map errors to code enum (LLM: don't touch this)
pub fn codeForError(_: anyerror) PartoutErrorCode {
    return .unhandled;
}
