// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const ffi = @import("../c/exports.zig");

const core = @import("../core/exports.zig");
const io = @import("io_common.zig");
const api = core.api;
const io_c = ffi.io;

pub const LinkDescriptor = *SocketWrapper;
pub const TunDescriptor = *TunWrapper;

// FIXME: ###, Windows, SocketWrapper
pub const SocketWrapper = struct {
    allocator: std.mem.Allocator,

    // FIXME: ###, Windows, Open and configure the native socket using endpoint and options.
    pub fn create(
        allocator: std.mem.Allocator,
        endpoint: ?api.ExtendedEndpoint,
        options: io.SocketOptions,
    ) std.mem.Allocator.Error!?*SocketWrapper {
        const self = try allocator.create(SocketWrapper);
        _ = endpoint;
        _ = options;
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    // FIXME: ###, Windows, Close the native socket and watch handle.
    pub fn destroy(self: *SocketWrapper) void {
        self.allocator.destroy(self);
    }

    // FIXME: ###, Windows, Supply the bound address and native handle with Windows I/O.
    pub fn localAddress(_: *const SocketWrapper) !io.SocketAddress {
        @panic("Windows SocketWrapper.localAddress is not implemented");
    }

    // FIXME: ###, Windows, Expose native packet I/O and readiness through the descriptor.
    pub fn cleanup(self: *SocketWrapper) void {
        self.destroy();
    }

    pub fn linkDescriptor(self: *SocketWrapper) LinkDescriptor {
        return self;
    }

    pub fn socketWrapper(self: *SocketWrapper) ?*SocketWrapper {
        return self;
    }
};

// FIXME: ###, Windows, TunWrapper
pub const TunWrapper = struct {
    allocator: std.mem.Allocator,
    tun: io_c.pp_tun,

    pub fn create(allocator: std.mem.Allocator, tun: io_c.pp_tun) std.mem.Allocator.Error!*TunWrapper {
        const self = try allocator.create(TunWrapper);
        self.* = .{
            .allocator = allocator,
            .tun = tun,
        };
        return self;
    }

    // FIXME: ###, Windows, Release the native tunnel and packet-I/O resources.
    pub fn destroy(self: *TunWrapper) void {
        io_c.pp_tun_free(self.tun);
        self.allocator.destroy(self);
    }

    // FIXME: ###, Windows, Expose native TUN packet I/O and readiness.
    pub fn cleanup(self: *TunWrapper) void {
        self.destroy();
    }

    pub fn tunDescriptor(self: *TunWrapper) !TunDescriptor {
        return self;
    }

    pub fn tunWrapper(self: *TunWrapper) ?*TunWrapper {
        return self;
    }

    // FIXME: ###, Windows, Expose the native TUN watch handle.
    pub fn muxDescriptor(_: *const TunWrapper) ?io_c.pp_fd {
        @panic("Windows TunWrapper.muxDescriptor is not implemented");
    }
};
