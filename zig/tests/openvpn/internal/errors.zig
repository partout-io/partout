// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const errors = source.openvpn_internal.errors;

test "coarse failures map to ConnectionReporter categories" {
    try std.testing.expectEqual(api.PartoutErrorCode.timeout, errors.partoutCode(error.Timeout));
    try std.testing.expectEqual(api.PartoutErrorCode.authentication, errors.partoutCode(error.BadCredentials));
    try std.testing.expectEqual(
        api.PartoutErrorCode.openVPNUnsupportedAlgorithm,
        errors.partoutCode(error.UnsupportedAlgorithm),
    );
    try std.testing.expectEqual(api.PartoutErrorCode.crypto, errors.partoutCode(error.CryptoFailure));
    try std.testing.expectEqual(api.PartoutErrorCode.openVPNTLSFailure, errors.partoutCode(error.TLSFailure));
    try std.testing.expectEqual(
        api.PartoutErrorCode.openVPNCompressionMismatch,
        errors.partoutCode(error.CompressionMismatch),
    );
}

test "unexpected session failures become reconnect requests" {
    try std.testing.expectEqual(error.Reconnect, errors.sessionError(error.OutOfMemory));
    try std.testing.expectEqual(error.ConnectionFailure, errors.sessionError(error.DataPathFailure));
    try std.testing.expectEqual(error.ConnectionFailure, errors.sessionError(error.ConnectionFailure));
    try std.testing.expectEqual(null, errors.partoutCode(error.Reconnect));
}
