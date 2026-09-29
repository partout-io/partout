// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Shared reachability, sides, and errors for socket and TUN I/O.
//! Platform-specific descriptors, options, and wrappers belong to the backends
//! selected by `io.zig`. This module does not import either backend.

const std = @import("std");

const io_mod = @This();
const core = @import("../core/exports.zig");
const ffi = @import("../c/exports.zig");

const api = core.api;
pub const io_c = ffi.io;

pub const Datagram = struct { payload: []const u8, address: SocketAddress };
pub const ReachabilityInfo = io_c.pp_reachability;
pub const SocketAddress = io_c.pp_socket_address;
pub const SocketType = api.SocketType;

/// Resolved peer address and transport, copied by value across queue boundaries.
pub const SocketEndpoint = struct {
    address: SocketAddress,
    type: SocketType,

    pub fn init(endpoint: api.ExtendedEndpoint) error{InvalidEndpoint}!SocketEndpoint {
        return .{ .address = try socketAddress(endpoint), .type = endpoint.plainSocketType() };
    }

    /// Returns a textual IP borrowed from buffer, for tunnel settings and logging.
    pub fn ipAddress(self: SocketEndpoint, buffer: []u8) error{ InvalidEndpoint, NoSpaceLeft }!api.Address {
        const bytes = self.address.address;
        return switch (self.address.family) {
            4 => .{ .raw = try std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }), .family = .v4 },
            6 => blk: {
                const ip = std.Io.net.Ip6Address.Unresolved{ .bytes = bytes, .interface_name = null };
                const text = if (self.address.scope_id == 0)
                    try std.fmt.bufPrint(buffer, "{f}", .{ip})
                else
                    try std.fmt.bufPrint(buffer, "{f}%{d}", .{ ip, self.address.scope_id });
                break :blk .{ .raw = text, .family = .v6 };
            },
            else => error.InvalidEndpoint,
        };
    }
};

pub const Side = enum {
    link,
    tun,
};

pub const Error = std.mem.Allocator.Error || error{
    WouldBlock,
    Backpressure,
    EndOfStream,
    LibcFailure,
};

pub const SocketOptions = struct {
    /// Used only for unconnected UDP. Enabling both selects one dual-stack socket.
    ipv4: bool = true,
    ipv6: bool = true,
    port: u16 = 0,
    timeout_ms: c_int = 0,
    buf_size: c_int = 0,
    reachability: ?io_c.pp_reachability = null,
    configure: io_c.pp_socket_configure = null,
    configure_ctx: ?*anyopaque = null,
};

/// Converts a resolved endpoint; hostnames and named IPv6 zones must be resolved first.
pub fn socketAddress(endpoint: api.ExtendedEndpoint) error{InvalidEndpoint}!SocketAddress {
    var text = endpoint.address;
    var scope: u32 = 0;
    if (std.mem.lastIndexOfScalar(u8, text, '%')) |index| {
        scope = std.fmt.parseInt(u32, text[index + 1 ..], 10) catch return error.InvalidEndpoint;
        text = text[0..index];
    }
    const parsed = std.Io.net.IpAddress.parse(text, endpoint.proto.port) catch return error.InvalidEndpoint;
    var result = std.mem.zeroes(SocketAddress);
    result.port = endpoint.proto.port;
    switch (parsed) {
        .ip4 => |value| {
            if (text.len != endpoint.address.len) return error.InvalidEndpoint;
            result.family = 4;
            @memcpy(result.address[0..4], &value.bytes);
        },
        .ip6 => |value| {
            result.family = 6;
            result.address = value.bytes;
            result.scope_id = scope;
        },
    }
    return result;
}

pub fn reachabilityNone() io_c.pp_reachability {
    var reachability = std.mem.zeroes(io_c.pp_reachability);
    reachability.reachable = false;
    return reachability;
}

pub const testing = struct {
    pub fn reachable(value: bool) ReachabilityInfo {
        var result = std.mem.zeroes(ReachabilityInfo);
        result.reachable = value;
        return result;
    }
    pub const reachabilityNone = io_mod.reachabilityNone;
};
