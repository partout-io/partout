// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Compile surface for the internal one-entity-per-file OpenVPN port.

const std = @import("std");

pub const c = @import("c.zig").api;
pub const errors = @import("errors.zig");

pub const ActiveContext = @import("active_context.zig").ActiveContext;
pub const ActivePhase = @import("active_phase.zig").ActivePhase;
pub const AuthSerializer = @import("auth_serializer.zig").AuthSerializer;
pub const Authenticator = @import("authenticator.zig").Authenticator;
pub const BidirectionalState = @import("bidirectional_state.zig").BidirectionalState;
pub const CControlPacket = @import("c_control_packet.zig").CControlPacket;
pub const CDataPath = @import("c_data_path.zig").CDataPath;
pub const CPacketCode = @import("c_packet_code.zig").CPacketCode;
pub const ConfigurationHelpers = @import("configuration_helpers.zig");
pub const ConnectionOptions = @import("connection_options.zig").ConnectionOptions;
pub const Constants = @import("constants.zig").Constants;
pub const ControlChannelConstants = @import("control_channel_constants.zig").ControlChannel;
pub const ControlChannelSerializer = @import("control_channel_serializer.zig").ControlChannelSerializer;
pub const ControlChannelV3 = @import("control_channel_v3.zig").ControlChannelV3;
pub const CredentialsHelpers = @import("credentials_helpers.zig");
pub const CryptSerializer = @import("crypt_serializer.zig").CryptSerializer;
pub const CryptV2Serializer = @import("crypt_v2_serializer.zig").CryptV2Serializer;
pub const CryptoBackend = @import("crypto_backend.zig").CryptoBackend;
pub const CryptoKeyPair = @import("crypto_key_pair.zig").CryptoKeyPair;
pub const CryptoKeys = @import("crypto_keys.zig").CryptoKeys;
pub const CryptoKeysBridge = @import("crypto_keys_bridge.zig").CryptoKeysBridge;
pub const CryptoKeysPRF = @import("crypto_keys_prf.zig").CryptoKeysPRF;
pub const DataChannel = @import("data_channel.zig").DataChannel;
pub const DataChannelConstants = @import("data_channel_constants.zig").DataChannel;
pub const DataLink = @import("data_link.zig").DataLink;
pub const DataLinkPair = @import("data_link_pair.zig").DataLinkPair;
pub const DataPathDecryptResult = @import("data_path_decrypt_result.zig").DataPathDecryptResult;
pub const DataPathDecryptedAndParsedTuple = @import("data_path_decrypted_and_parsed_tuple.zig").DataPathDecryptedAndParsedTuple;
pub const DataPathDecryptedTuple = @import("data_path_decrypted_tuple.zig").DataPathDecryptedTuple;
pub const DataPathParameters = @import("data_path_parameters.zig").DataPathParameters;
pub const DataPathProtocol = @import("data_path_protocol.zig").DataPathProtocol;
pub const DataPathTestingProtocol = @import("data_path_testing_protocol.zig").DataPathTestingProtocol;
pub const DataPathWrapper = @import("data_path_wrapper.zig").DataPathWrapper;
pub const Factories = @import("factories.zig");
pub const Handshake = @import("handshake.zig").Handshake;
pub const IdleContext = @import("idle_context.zig").IdleContext;
pub const KeyConstants = @import("key_constants.zig").Keys;
pub const LinkProcessor = @import("link_processor.zig").LinkProcessor;
pub const NativeTLSConstants = @import("native_tls_constants.zig").NativeTLSConstants;
pub const NativeTLSWrapper = @import("native_tls_wrapper.zig").NativeTLSWrapper;
pub const NegotiationHistory = @import("negotiation_history.zig").NegotiationHistory;
pub const NegotiatorOptions = @import("negotiator_options.zig").NegotiatorOptions;
pub const NegotiatorState = @import("negotiator_state.zig").NegotiatorState;
pub const NegotiatorV3 = @import("negotiator_v3.zig").NegotiatorV3;
pub const NetworkSettingsBuilder = @import("network_settings_builder.zig").NetworkSettingsBuilder;
pub const OCCPacket = @import("occ_packet.zig").OCCPacket;
pub const OpenVPNTLS = @import("openvpn_tls.zig").OpenVPNTLS;
pub const PacketDirection = @import("packet_direction.zig").PacketDirection;
pub const PacketProcessor = @import("packet_processor.zig").PacketProcessor;
pub const PIAHardReset = @import("pia_hard_reset.zig").PIAHardReset;
pub const PlainSerializer = @import("plain_serializer.zig").PlainSerializer;
pub const PRFInput = @import("prf_input.zig").PRFInput;
pub const PRNG = @import("prng.zig").PRNG;
pub const PushReply = @import("push_reply.zig").PushReply;
pub const RenegotiationType = @import("renegotiation_type.zig").RenegotiationType;
pub const ServerOCC = @import("server_occ.zig").ServerOCC;
pub const Session = @import("session.zig").Session;
pub const SessionDelegate = @import("session_delegate.zig").SessionDelegate;
pub const SessionProtocol = @import("session_protocol.zig").SessionProtocol;
pub const SessionState = @import("session_state.zig").SessionState;
pub const SimpleKeyDecrypter = @import("simple_key_decrypter.zig").SimpleKeyDecrypter;
pub const StaticKeyHelpers = @import("static_key_helpers.zig");
pub const TimeHelpers = @import("time_helpers.zig");
pub const TLSParameters = @import("tls_parameters.zig").TLSParameters;
pub const TLSProtocol = @import("tls_protocol.zig").TLSProtocol;
pub const TLSWrapper = @import("tls_wrapper.zig").TLSWrapper;
pub const ZeroingData = @import("zeroing_data.zig").ZeroingData;

test {
    std.testing.refAllDecls(@This());
    inline for (.{
        ActiveContext,
        ActivePhase,
        AuthSerializer,
        Authenticator,
        CControlPacket,
        CDataPath,
        CPacketCode,
        ConnectionOptions,
        Constants,
        ControlChannelConstants,
        ControlChannelSerializer,
        ControlChannelV3,
        CryptSerializer,
        CryptV2Serializer,
        CryptoBackend,
        CryptoKeyPair,
        CryptoKeys,
        CryptoKeysBridge,
        CryptoKeysPRF,
        DataChannel,
        DataChannelConstants,
        DataLink,
        DataLinkPair,
        DataPathDecryptResult,
        DataPathDecryptedAndParsedTuple,
        DataPathDecryptedTuple,
        DataPathParameters,
        DataPathProtocol,
        DataPathTestingProtocol,
        DataPathWrapper,
        Handshake,
        IdleContext,
        KeyConstants,
        LinkProcessor,
        NativeTLSConstants,
        NativeTLSWrapper,
        NegotiationHistory,
        NegotiatorOptions,
        NegotiatorState,
        NegotiatorV3,
        NetworkSettingsBuilder,
        OCCPacket,
        OpenVPNTLS,
        PacketDirection,
        PacketProcessor,
        PIAHardReset,
        PlainSerializer,
        PRFInput,
        PRNG,
        PushReply,
        RenegotiationType,
        ServerOCC,
        Session,
        SessionDelegate,
        SessionProtocol,
        SessionState,
        SimpleKeyDecrypter,
        TLSParameters,
        TLSProtocol,
        TLSWrapper,
        ZeroingData,
    }) |Type| std.testing.refAllDecls(Type);
    _ = ActiveContext;
    _ = ActivePhase;
    _ = AuthSerializer;
    _ = Authenticator;
    _ = BidirectionalState;
    _ = CControlPacket;
    _ = CDataPath;
    _ = CPacketCode;
    _ = ConnectionOptions;
    _ = Constants;
    _ = ControlChannelConstants;
    _ = ControlChannelSerializer;
    _ = ControlChannelV3;
    _ = CryptSerializer;
    _ = CryptV2Serializer;
    _ = CryptoKeyPair;
    _ = CryptoKeys;
    _ = CryptoKeysBridge;
    _ = CryptoKeysPRF;
    _ = DataChannel;
    _ = DataChannelConstants;
    _ = DataLink;
    _ = DataLinkPair;
    _ = DataPathDecryptResult;
    _ = DataPathDecryptedAndParsedTuple;
    _ = DataPathDecryptedTuple;
    _ = DataPathParameters;
    _ = DataPathProtocol;
    _ = DataPathTestingProtocol;
    _ = DataPathWrapper;
    _ = Factories;
    _ = Handshake;
    _ = IdleContext;
    _ = KeyConstants;
    _ = LinkProcessor;
    _ = NativeTLSConstants;
    _ = NativeTLSWrapper;
    _ = NegotiationHistory;
    _ = NegotiatorOptions;
    _ = NegotiatorState;
    _ = NegotiatorV3;
    _ = NetworkSettingsBuilder;
    _ = OCCPacket;
    _ = OpenVPNTLS;
    _ = PacketDirection;
    _ = PacketProcessor;
    _ = PIAHardReset;
    _ = PlainSerializer;
    _ = PRFInput;
    _ = PRNG;
    _ = PushReply;
    _ = RenegotiationType;
    _ = ServerOCC;
    _ = Session;
    _ = SessionDelegate;
    _ = SessionProtocol;
    _ = SessionState;
    _ = SimpleKeyDecrypter;
    _ = StaticKeyHelpers;
    _ = TimeHelpers;
    _ = TLSParameters;
    _ = TLSProtocol;
    _ = TLSWrapper;
    _ = ZeroingData;
    _ = errors;
}
