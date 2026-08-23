// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

pub const c = @cImport({
    @cInclude("c/android_import_compat.h");
    @cInclude("openvpn/openvpn.h");
});
const c_exports_mod = @import("../../c/exports.zig");

pub fn BidirectionalState(comptime T: type) type {
    return struct {
        reset_value: T,
        inbound: T,
        outbound: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{
                .reset_value = value,
                .inbound = value,
                .outbound = value,
            };
        }

        pub fn reset(self: *Self) void {
            self.inbound = self.reset_value;
            self.outbound = self.reset_value;
        }
    };
}

pub const c_data_path_error_empty = c.openvpn_dp_error{
    .dp_code = c.OpenVPNDataPathErrorNone,
    .crypto_code = c_exports_mod.crypto.PPCryptoErrorNone,
};
