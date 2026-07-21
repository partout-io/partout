// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const core = @import("../../core/exports.zig");
const c_crypto = @import("../../c/exports.zig").crypto;

const api = core.api;

/// Borrowed arguments used to create a TLS engine.
pub const TLSParameters = struct {
    fnt: c_crypto.pp_crypto_tls_fnt,
    caches_directory: []const u8,
    configuration: *const api.OpenVPNConfiguration,
    verification: Verification = .{},

    pub const Verification = struct {
        context: ?*anyopaque = null,
        callback: *const fn (?*anyopaque) void = ignore,

        fn ignore(_: ?*anyopaque) void {}

        pub fn failed(self: Verification) void {
            self.callback(self.context);
        }
    };
};
