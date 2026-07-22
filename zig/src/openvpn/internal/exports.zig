// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Compile surface for the internal OpenVPN implementation.

const std = @import("std");

pub const c = @import("c.zig").api;
pub const errors = @import("errors.zig");

pub const ActiveContext = @import("session_context.zig").ActiveContext;
pub const ActivePhase = @import("active_phase.zig").ActivePhase;
pub const AuthSerializer = @import("serialization.zig").AuthSerializer;
pub const Authenticator = @import("auth.zig").Authenticator;
pub const BidirectionalState = @import("bidirectional_state.zig").BidirectionalState;
pub const ControlPacket = @import("control.zig").ControlPacket;
pub const DataPath = @import("data.zig").DataPath;
pub const PacketCode = @import("control.zig").PacketCode;
pub const ConfigurationHelpers = @import("configuration_helpers.zig");
pub const ConnectionOptions = @import("connection_options.zig").ConnectionOptions;
pub const Constants = @import("constants.zig").Constants;
pub const ControlChannelConstants = @import("control_channel_constants.zig").ControlChannel;
pub const Serializer = @import("serialization.zig").Serializer;
pub const ControlChannel = @import("control.zig").ControlChannel(Serializer);
pub const CredentialsHelpers = @import("credentials_helpers.zig");
pub const CryptSerializer = @import("serialization.zig").CryptSerializer;
pub const CryptV2Serializer = @import("serialization.zig").CryptV2Serializer;
pub const CryptoBackend = @import("crypto_backend.zig").CryptoBackend;
pub const CryptoKeyPair = @import("crypto_key_pair.zig").CryptoKeyPair;
pub const CryptoKeys = @import("crypto_keys.zig").CryptoKeys;
pub const CryptoKeysBridge = @import("crypto_keys_bridge.zig").CryptoKeysBridge;
pub const PRF = @import("auth.zig").PRF;
pub const DataChannel = @import("data.zig").DataChannel;
pub const DataChannelConstants = @import("data.zig").DataConstants;
pub const DataLink = @import("data.zig").DataLink;
pub const DataLinkPair = @import("data.zig").DataLinkPair;
pub const DataPathDecryptResult = @import("data.zig").DataPathDecryptResult;
pub const DataPathDecryptedAndParsedTuple = @import("data.zig").DataPathDecryptedAndParsedTuple;
pub const DataPathDecryptedTuple = @import("data.zig").DataPathDecryptedTuple;
pub const DataPathParameters = @import("data.zig").DataPathParameters;
pub const DataPathWrapper = @import("data.zig").DataPathWrapper;
pub const Handshake = @import("auth.zig").Handshake;
pub const IdleContext = @import("session_context.zig").IdleContext;
pub const KeyConstants = @import("key_constants.zig").Keys;
pub const LinkProcessor = @import("processing.zig").LinkProcessor;
pub const TLSConstants = @import("tls.zig").TLSConstants;
pub const NegotiationHistory = @import("session_negotiator.zig").NegotiationHistory;
pub const NegotiatorOptions = @import("session_negotiator.zig").NegotiatorOptions;
pub const NegotiatorState = @import("session_negotiator.zig").NegotiatorState;
pub const Negotiator = @import("session_negotiator.zig").Negotiator;
pub const NetworkSettingsBuilder = @import("network_settings_builder.zig").NetworkSettingsBuilder;
pub const OCCPacket = @import("occ_packet.zig").OCCPacket;
pub const PacketDirection = @import("processing.zig").PacketDirection;
pub const PacketProcessor = @import("processing.zig").PacketProcessor;
pub const PIAHardReset = @import("pia_hard_reset.zig").PIAHardReset;
pub const PlainSerializer = @import("serialization.zig").PlainSerializer;
pub const PRFInput = @import("prf_input.zig").PRFInput;
pub const PRNG = @import("prng.zig").PRNG;
pub const PushReply = @import("push_reply.zig").PushReply;
pub const RenegotiationType = @import("renegotiation_type.zig").RenegotiationType;
pub const ServerOCC = @import("server_occ.zig").ServerOCC;
pub const Session = @import("session.zig").Session;
pub const SessionDelegate = @import("session_delegate.zig").SessionDelegate;
pub const SessionState = @import("session_state.zig").SessionState;
pub const SimpleKeyDecrypter = @import("simple_key_decrypter.zig").SimpleKeyDecrypter;
pub const StaticKeyHelpers = @import("static_key_helpers.zig");
pub const TimeHelpers = @import("time_helpers.zig");
pub const TLSParameters = @import("tls.zig").TLSParameters;
pub const TLSWrapper = @import("tls.zig").TLSWrapper;
pub const ZeroingData = @import("zeroing_data.zig").ZeroingData;

test {
    std.testing.refAllDecls(@This());
    inline for (.{
        ActiveContext,
        ActivePhase,
        AuthSerializer,
        Authenticator,
        ControlPacket,
        DataPath,
        PacketCode,
        ConnectionOptions,
        Constants,
        ControlChannelConstants,
        Serializer,
        ControlChannel,
        CryptSerializer,
        CryptV2Serializer,
        CryptoBackend,
        CryptoKeyPair,
        CryptoKeys,
        CryptoKeysBridge,
        PRF,
        DataChannel,
        DataChannelConstants,
        DataLink,
        DataLinkPair,
        DataPathDecryptResult,
        DataPathDecryptedAndParsedTuple,
        DataPathDecryptedTuple,
        DataPathParameters,
        DataPathWrapper,
        Handshake,
        IdleContext,
        KeyConstants,
        LinkProcessor,
        TLSConstants,
        TLSWrapper,
        NegotiationHistory,
        NegotiatorOptions,
        NegotiatorState,
        Negotiator,
        NetworkSettingsBuilder,
        OCCPacket,
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
        SessionState,
        SimpleKeyDecrypter,
        TLSParameters,
        ZeroingData,
    }) |Type| std.testing.refAllDecls(Type);
    _ = ActiveContext;
    _ = ActivePhase;
    _ = AuthSerializer;
    _ = Authenticator;
    _ = BidirectionalState;
    _ = ControlPacket;
    _ = DataPath;
    _ = PacketCode;
    _ = ConnectionOptions;
    _ = Constants;
    _ = ControlChannelConstants;
    _ = Serializer;
    _ = ControlChannel;
    _ = CryptSerializer;
    _ = CryptV2Serializer;
    _ = CryptoKeyPair;
    _ = CryptoKeys;
    _ = CryptoKeysBridge;
    _ = PRF;
    _ = DataChannel;
    _ = DataChannelConstants;
    _ = DataLink;
    _ = DataLinkPair;
    _ = DataPathDecryptResult;
    _ = DataPathDecryptedAndParsedTuple;
    _ = DataPathDecryptedTuple;
    _ = DataPathParameters;
    _ = DataPathWrapper;
    _ = Handshake;
    _ = IdleContext;
    _ = KeyConstants;
    _ = LinkProcessor;
    _ = TLSConstants;
    _ = TLSWrapper;
    _ = NegotiationHistory;
    _ = NegotiatorOptions;
    _ = NegotiatorState;
    _ = Negotiator;
    _ = NetworkSettingsBuilder;
    _ = OCCPacket;
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
    _ = SessionState;
    _ = SimpleKeyDecrypter;
    _ = StaticKeyHelpers;
    _ = TimeHelpers;
    _ = TLSParameters;
    _ = ZeroingData;
    _ = errors;
}
