// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const c = @import("c.zig").api;

/// Borrowed input to the OpenVPN TLS 1.0 PRF.
pub const PRFInput = struct {
    fnt: c.pp_crypto_fnt,
    label: []const u8,
    secret: []const u8,
    client_seed: []const u8,
    server_seed: []const u8,
    client_session_id: ?[]const u8 = null,
    server_session_id: ?[]const u8 = null,
    size: usize,
};
