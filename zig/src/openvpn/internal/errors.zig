// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! OpenVPN errors and the mapping used at the Swift/Zig boundary.
//!
//! Swift can attach payloads to `Error` enum cases. Zig errors do not carry
//! payloads, so the C wrappers below retain native codes while their
//! `toError()` methods expose stable errors suitable for `try`/`catch`.

const std = @import("std");

const api = @import("../../core/exports.zig").api;
const c_crypto = @import("../../c/exports.zig").crypto;
const c = @import("c.zig").api;

pub const PPCryptoError = error{
    CryptoCreation,
    CryptoHMACCalculation,
};

pub const OpenVPNDataPathError = error{
    DataPathCreation,
    DataPathAlgorithm,
    DataPathOverflow,
};

pub const PPTLSError = error{
    MissingCA,
    TLSStart,
    TLSPeerVerification,
    TLSNoData,
    TLSEncryption,
};

pub const OpenVPNSessionError = error{
    Recoverable,
    NegotiationTimeout,
    MissingSessionId,
    SessionMismatch,
    BadKey,
    ControlChannelFailure,
    WrongControlDataPrefix,
    BadCredentials,
    BadCredentialsWithLocalOptions,
    MalformedPushReply,
    WriteTimeout,
    PingTimeout,
    StaleSession,
    ServerCompression,
    NoRouting,
    ServerShutdown,
    Assertion,
    NativeFailure,
};

// Supporting Zig error sets live here as well, keeping every translated and
// implementation-specific OpenVPN error declaration in one file.
pub const PRNGError = error{
    RandomGeneration,
};

pub const PIAHardResetError = PRNGError || error{
    Assertion,
};

pub const PacketProcessorError = error{
    PacketTooLarge,
};

pub const NetworkSettingsError = error{
    InvalidAddress,
};

pub const ZeroingDataError = error{
    OutOfBounds,
};

pub const CredentialsError = error{
    OTPRequired,
};

pub const StaticKeyError = api.EncodeError || error{
    InvalidStaticKey,
    MissingStaticKeyDirection,
};

pub const CControlPacketError = error{
    AckIdsTooLong,
    InvalidAck,
    InvalidKey,
    InvalidPacketId,
    InvalidSessionId,
};

pub const PlainSerializerError = error{
    AckPacketWithoutIds,
    AckPacketWithoutRemoteSessionId,
    InvalidRange,
    MissingAcks,
    MissingAckSize,
    MissingOpcode,
    MissingPacketId,
    MissingRemoteSessionId,
    MissingSessionId,
    UnknownCode,
};

pub const InvalidSessionIdError = error{
    InvalidSessionId,
};

pub const PingTimeoutError = error{
    PingTimeout,
};

pub const OpenVPNErrorCode = enum(i32) {
    cryptoRandomGenerator = 101,
    cryptoHMAC = 102,
    cryptoEncryption = 103,
    cryptoAlgorithm = 104,
    tlscaUse = 202,
    tlscaPeerVerification = 203,
    tlsClientCertificateRead = 204,
    tlsClientCertificateUse = 205,
    tlsClientKeyRead = 206,
    tlsClientKeyUse = 207,
    tlsHandshake = 210,
    tlsServerCertificate = 211,
    tlsServerEKU = 212,
    tlsServerHost = 213,
    dataPathOverflow = 301,
    dataPathPeerIdMismatch = 302,
    dataPathCompression = 303,
    unknown = 999,
};

pub const CCryptoError = struct {
    code: c_crypto.pp_crypto_error_code,

    pub fn init(code: c_crypto.pp_crypto_error_code) CCryptoError {
        std.debug.assert(code != c_crypto.PPCryptoErrorNone);
        return .{ .code = code };
    }

    pub fn toError(self: CCryptoError) anyerror {
        return switch (self.code) {
            c_crypto.PPCryptoErrorHMAC => error.CryptoHMAC,
            c_crypto.PPCryptoErrorEncryption => error.CryptoEncryption,
            else => error.CryptoFailure,
        };
    }

    pub fn openVPNCode(self: CCryptoError) OpenVPNErrorCode {
        return switch (self.code) {
            c_crypto.PPCryptoErrorHMAC => .cryptoHMAC,
            c_crypto.PPCryptoErrorEncryption => .cryptoEncryption,
            else => .unknown,
        };
    }
};

pub const CDataPathError = struct {
    code: c.openvpn_dp_error_code,
    crypto_code: c_crypto.pp_crypto_error_code = c_crypto.PPCryptoErrorNone,

    pub fn init(code: c.openvpn_dp_error_code) CDataPathError {
        std.debug.assert(code != c.OpenVPNDataPathErrorNone);
        return .{ .code = code };
    }

    pub fn fromNative(native: c.openvpn_dp_error) CDataPathError {
        std.debug.assert(native.dp_code != c.OpenVPNDataPathErrorNone);
        return .{
            .code = native.dp_code,
            .crypto_code = native.crypto_code,
        };
    }

    pub fn toError(self: CDataPathError) anyerror {
        return switch (self.code) {
            c.OpenVPNDataPathErrorPeerIdMismatch => error.DataPathPeerIdMismatch,
            c.OpenVPNDataPathErrorCompression => error.DataPathCompression,
            c.OpenVPNDataPathErrorCrypto => CCryptoError.init(self.crypto_code).toError(),
            else => error.DataPathFailure,
        };
    }

    pub fn openVPNCode(self: CDataPathError) OpenVPNErrorCode {
        return switch (self.code) {
            c.OpenVPNDataPathErrorPeerIdMismatch => .dataPathPeerIdMismatch,
            c.OpenVPNDataPathErrorCompression => .dataPathCompression,
            c.OpenVPNDataPathErrorCrypto => CCryptoError.init(self.crypto_code).openVPNCode(),
            else => .unknown,
        };
    }
};

pub const CTLSError = struct {
    code: c_crypto.pp_tls_error_code,

    pub fn init(code: c_crypto.pp_tls_error_code) CTLSError {
        std.debug.assert(code != c_crypto.PPTLSErrorNone);
        return .{ .code = code };
    }

    pub fn toError(self: CTLSError) anyerror {
        return switch (self.code) {
            c_crypto.PPTLSErrorCARead => error.TLSCARead,
            c_crypto.PPTLSErrorCAUse => error.TLSCAUse,
            c_crypto.PPTLSErrorCAPeerVerification => error.TLSCAPeerVerification,
            c_crypto.PPTLSErrorClientCertificateRead => error.TLSClientCertificateRead,
            c_crypto.PPTLSErrorClientCertificateUse => error.TLSClientCertificateUse,
            c_crypto.PPTLSErrorClientKeyRead => error.TLSClientKeyRead,
            c_crypto.PPTLSErrorClientKeyUse => error.TLSClientKeyUse,
            c_crypto.PPTLSErrorHandshake => error.TLSHandshake,
            c_crypto.PPTLSErrorServerEKU => error.TLSServerEKU,
            c_crypto.PPTLSErrorServerHost => error.TLSServerHost,
            else => error.TLSFailure,
        };
    }

    pub fn openVPNCode(self: CTLSError) OpenVPNErrorCode {
        return switch (self.code) {
            c_crypto.PPTLSErrorCAUse => .tlscaUse,
            c_crypto.PPTLSErrorCAPeerVerification => .tlscaPeerVerification,
            c_crypto.PPTLSErrorClientCertificateRead => .tlsClientCertificateRead,
            c_crypto.PPTLSErrorClientCertificateUse => .tlsClientCertificateUse,
            c_crypto.PPTLSErrorClientKeyRead => .tlsClientKeyRead,
            c_crypto.PPTLSErrorClientKeyUse => .tlsClientKeyUse,
            c_crypto.PPTLSErrorHandshake => .tlsHandshake,
            c_crypto.PPTLSErrorServerEKU => .tlsServerEKU,
            c_crypto.PPTLSErrorServerHost => .tlsServerHost,
            else => .unknown,
        };
    }
};

pub fn openVPNCode(err: anyerror) OpenVPNErrorCode {
    return switch (err) {
        error.RandomGeneration => .cryptoRandomGenerator,
        error.CryptoHMAC => .cryptoHMAC,
        error.CryptoEncryption => .cryptoEncryption,
        error.CryptoCreation,
        error.CryptoHMACCalculation,
        error.DataPathAlgorithm,
        error.DataPathCreation,
        => .cryptoAlgorithm,
        error.DataPathOverflow => .dataPathOverflow,
        error.DataPathPeerIdMismatch => .dataPathPeerIdMismatch,
        error.DataPathCompression => .dataPathCompression,
        error.TLSCAUse => .tlscaUse,
        error.TLSCAPeerVerification => .tlscaPeerVerification,
        error.TLSClientCertificateRead => .tlsClientCertificateRead,
        error.TLSClientCertificateUse => .tlsClientCertificateUse,
        error.TLSClientKeyRead => .tlsClientKeyRead,
        error.TLSClientKeyUse => .tlsClientKeyUse,
        error.TLSServerEKU => .tlsServerEKU,
        error.TLSServerHost => .tlsServerHost,
        error.TLSHandshake,
        error.MissingCA,
        error.TLSPeerVerification,
        error.TLSNoData,
        error.TLSEncryption,
        error.TLSStart,
        error.TLSFailure,
        => .tlsHandshake,
        else => .unknown,
    };
}

pub fn partoutCode(err: anyerror) api.PartoutErrorCode {
    return switch (err) {
        error.NegotiationTimeout,
        error.PingTimeout,
        error.WriteTimeout,
        => .timeout,
        error.BadCredentials => .authentication,
        error.BadCredentialsWithLocalOptions => .openVPNRecoverableAuthentication,
        error.ServerCompression,
        error.DataPathCompression,
        => .openVPNCompressionMismatch,
        error.ServerShutdown => .openVPNServerShutdown,
        error.NoRouting => .openVPNNoRouting,
        error.CryptoHMAC,
        error.CryptoEncryption,
        error.RandomGeneration,
        => .crypto,
        error.CryptoCreation,
        error.CryptoHMACCalculation,
        error.DataPathAlgorithm,
        error.DataPathCreation,
        => .openVPNUnsupportedAlgorithm,
        error.MissingCA,
        error.TLSStart,
        error.TLSPeerVerification,
        error.TLSNoData,
        error.TLSEncryption,
        error.TLSCARead,
        error.TLSCAUse,
        error.TLSCAPeerVerification,
        error.TLSClientCertificateRead,
        error.TLSClientCertificateUse,
        error.TLSClientKeyRead,
        error.TLSClientKeyUse,
        error.TLSHandshake,
        error.TLSServerEKU,
        error.TLSServerHost,
        => .openVPNTLSFailure,
        else => .openVPNConnectionFailure,
    };
}

pub fn isRecoverable(err: anyerror) bool {
    return switch (partoutCode(err)) {
        .timeout,
        .ioFailure,
        .networkChanged,
        .openVPNConnectionFailure,
        .openVPNRecoverableAuthentication,
        .openVPNServerShutdown,
        => true,
        else => err == error.Recoverable,
    };
}

test "OpenVPN error codes retain Swift raw values" {
    try std.testing.expectEqual(@as(i32, 101), @intFromEnum(OpenVPNErrorCode.cryptoRandomGenerator));
    try std.testing.expectEqual(@as(i32, 303), @intFromEnum(OpenVPNErrorCode.dataPathCompression));
    try std.testing.expectEqual(@as(i32, 999), @intFromEnum(OpenVPNErrorCode.unknown));
}

test "session errors map to public Partout errors" {
    try std.testing.expectEqual(api.PartoutErrorCode.timeout, partoutCode(error.PingTimeout));
    try std.testing.expectEqual(api.PartoutErrorCode.openVPNServerShutdown, partoutCode(error.ServerShutdown));
    try std.testing.expect(isRecoverable(error.ServerShutdown));
}

test "algorithm and native crypto failures retain distinct public mappings" {
    try std.testing.expectEqual(
        api.PartoutErrorCode.openVPNUnsupportedAlgorithm,
        partoutCode(error.CryptoHMACCalculation),
    );
    try std.testing.expectEqual(api.PartoutErrorCode.crypto, partoutCode(error.CryptoHMAC));
    try std.testing.expectEqual(api.PartoutErrorCode.openVPNTLSFailure, partoutCode(error.MissingCA));
}

test "random generation failures map to crypto errors" {
    try std.testing.expectEqual(
        OpenVPNErrorCode.cryptoRandomGenerator,
        openVPNCode(error.RandomGeneration),
    );
    try std.testing.expectEqual(
        api.PartoutErrorCode.crypto,
        partoutCode(error.RandomGeneration),
    );
}
