// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const io = @import("io_common.zig");
const io_c = io.io_c;

// Native handle types used by the Windows host ABI.
pub const FileDescriptor = io_c.pp_fd;
pub const SocketDescriptor = io_c.pp_socket_fd;

pub const LinkDescriptor = struct {
    socket: *SocketWrapper,

    pub fn cleanup(self: *LinkDescriptor) void {
        self.socket.destroy();
    }
};

pub const TunDescriptor = struct {
    tun: *TunWrapper,

    pub fn cleanup(self: *TunDescriptor) void {
        self.tun.deinit();
    }
};

// FIXME: ###, Windows SocketWrapper
pub const SocketWrapper = struct {
    allocator: std.mem.Allocator,

    pub fn create(
        allocator: std.mem.Allocator,
        options: io.SocketOptions,
    ) std.mem.Allocator.Error!?*SocketWrapper {
        const self = try allocator.create(SocketWrapper);
        _ = options;
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn destroy(self: *SocketWrapper) void {
        self.allocator.destroy(self);
    }

    pub fn linkDescriptor(self: *SocketWrapper) LinkDescriptor {
        return .{ .socket = self };
    }
};

// FIXME: ###, Windows TunWrapper
pub const TunWrapper = struct {
    pub fn init(_: io_c.pp_tun) TunWrapper {
        return .{};
    }

    pub fn deinit(_: *TunWrapper) void {}

    pub fn tunDescriptor(self: *TunWrapper) TunDescriptor {
        return .{ .tun = self };
    }
};
