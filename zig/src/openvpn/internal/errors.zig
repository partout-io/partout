// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Coarse OpenVPN failures and their eventual ConnectionReporter mapping.

const core_mod = @import("../../core/exports.zig");

const api = core_mod.api;
const log = core_mod.logging;

/// The only result retained after a session stops. Unknown failures are logged
/// and collapsed to `Reconnect`; reportable cases keep only their public
/// category.
pub const SessionError = error{
    BadCredentials,
    BadCredentialsWithLocalOptions,
    CompressionMismatch,
    ConnectionFailure,
    CryptoFailure,
    NoRouting,
    ServerShutdown,
    Timeout,
    TLSFailure,
    UnsupportedAlgorithm,
    Reconnect,
};

/// Classifies a session failure. Unknown runtime failures are useful only for
/// diagnostics: log them and return the reconnect signal without retaining
/// the original error. This is the sole deliberate `anyerror` boundary in the
/// OpenVPN implementation.
pub fn sessionError(err: anyerror) SessionError {
    const result: SessionError = switch (err) {
        error.BadCredentials => error.BadCredentials,
        error.BadCredentialsWithLocalOptions => error.BadCredentialsWithLocalOptions,
        error.CompressionMismatch => error.CompressionMismatch,
        error.ConnectionFailure, error.DataPathFailure, error.Assertion => error.ConnectionFailure,
        error.CryptoFailure => error.CryptoFailure,
        error.NoRouting => error.NoRouting,
        error.ServerShutdown => error.ServerShutdown,
        error.Timeout => error.Timeout,
        error.TLSFailure => error.TLSFailure,
        error.UnsupportedAlgorithm => error.UnsupportedAlgorithm,
        error.Reconnect => error.Reconnect,
        else => error.Reconnect,
    };
    if (result == error.Reconnect and err != error.Reconnect) {
        log.writef(.err, "OpenVPN session will reconnect after: {s}", .{@errorName(err)});
    }
    return result;
}

/// Maps a reportable session failure to ConnectionReporter.last_error.
/// Reconnect requests intentionally have no last-error value.
pub fn partoutCode(err: SessionError) ?api.PartoutErrorCode {
    return switch (err) {
        error.Reconnect => null,
        error.Timeout => .timeout,
        error.BadCredentials => .authentication,
        error.BadCredentialsWithLocalOptions => .openVPNRecoverableAuthentication,
        error.CompressionMismatch => .openVPNCompressionMismatch,
        error.ServerShutdown => .openVPNServerShutdown,
        error.NoRouting => .openVPNNoRouting,
        error.CryptoFailure => .crypto,
        error.UnsupportedAlgorithm => .openVPNUnsupportedAlgorithm,
        error.TLSFailure => .openVPNTLSFailure,
        error.ConnectionFailure => .openVPNConnectionFailure,
    };
}
