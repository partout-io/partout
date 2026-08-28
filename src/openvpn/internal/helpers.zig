// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

pub const openvpn_c = @cImport({
    @cInclude("openvpn/openvpn.h");
});
const ffi = @import("../../c/exports.zig");
const crypto_c = ffi.crypto;

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

pub const c_data_path_error_empty = openvpn_c.openvpn_dp_error{
    .dp_code = openvpn_c.OpenVPNDataPathErrorNone,
    .crypto_code = crypto_c.PPCryptoErrorNone,
};
