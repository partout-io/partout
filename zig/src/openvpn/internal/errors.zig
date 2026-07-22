// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Coarse OpenVPN failures and their eventual ConnectionReporter mapping.

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const c_mod = @import("c.zig");

const api = core_mod.api;
const c = c_mod.api;
const c_crypto = c_exports_mod.crypto;

/// Failures that must retain a distinct public last-error category.
pub const PRFError = error{
    UnsupportedAlgorithm,
};

pub const PRNGError = error{
    CryptoFailure,
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

pub const ControlPacketError = error{
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

pub fn cryptoError(code: c_crypto.pp_crypto_error_code) anyerror {
    std.debug.assert(code != c_crypto.PPCryptoErrorNone);
    return error.CryptoFailure;
}

pub fn dataPathError(native: c.openvpn_dp_error) anyerror {
    std.debug.assert(native.dp_code != c.OpenVPNDataPathErrorNone);
    return switch (native.dp_code) {
        c.OpenVPNDataPathErrorCompression => error.CompressionMismatch,
        c.OpenVPNDataPathErrorCrypto => cryptoError(native.crypto_code),
        else => error.DataPathFailure,
    };
}

pub fn tlsError(code: c_crypto.pp_tls_error_code) anyerror {
    std.debug.assert(code != c_crypto.PPTLSErrorNone);
    return error.TLSFailure;
}

/// Maps an internal failure to the only granularity exposed by
/// ConnectionReporter.last_error.
pub fn partoutCode(err: anyerror) api.PartoutErrorCode {
    return switch (err) {
        error.Timeout => .timeout,
        error.BadCredentials => .authentication,
        error.BadCredentialsWithLocalOptions => .openVPNRecoverableAuthentication,
        error.CompressionMismatch => .openVPNCompressionMismatch,
        error.ServerShutdown => .openVPNServerShutdown,
        error.NoRouting => .openVPNNoRouting,
        error.CryptoFailure => .crypto,
        error.UnsupportedAlgorithm => .openVPNUnsupportedAlgorithm,
        error.TLSFailure => .openVPNTLSFailure,
        else => .openVPNConnectionFailure,
    };
}

test "coarse failures map to ConnectionReporter categories" {
    try std.testing.expectEqual(api.PartoutErrorCode.timeout, partoutCode(error.Timeout));
    try std.testing.expectEqual(api.PartoutErrorCode.authentication, partoutCode(error.BadCredentials));
    try std.testing.expectEqual(
        api.PartoutErrorCode.openVPNUnsupportedAlgorithm,
        partoutCode(error.UnsupportedAlgorithm),
    );
    try std.testing.expectEqual(api.PartoutErrorCode.crypto, partoutCode(error.CryptoFailure));
    try std.testing.expectEqual(api.PartoutErrorCode.openVPNTLSFailure, partoutCode(error.TLSFailure));
    try std.testing.expectEqual(
        api.PartoutErrorCode.openVPNCompressionMismatch,
        partoutCode(error.CompressionMismatch),
    );
}
