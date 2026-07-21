// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const TLSParameters = @import("tls_parameters.zig").TLSParameters;
const TLSProtocol = @import("tls_protocol.zig").TLSProtocol;
const NativeTLSWrapper = @import("native_tls_wrapper.zig").NativeTLSWrapper;

/// Owning facade around a concrete TLS engine.
pub const TLSWrapper = struct {
    pub const Parameters = TLSParameters;

    tls: TLSProtocol,

    pub fn init(tls: TLSProtocol) TLSWrapper {
        return .{ .tls = tls };
    }

    pub fn native(
        allocator: std.mem.Allocator,
        parameters: TLSParameters,
    ) anyerror!TLSWrapper {
        return init(try NativeTLSWrapper.createProtocol(allocator, parameters));
    }

    pub fn deinit(self: *TLSWrapper) void {
        self.tls.deinit();
        self.* = undefined;
    }
};
