// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Shared reachability, sides, and errors for socket and TUN I/O.
//! Platform-specific descriptors, options, and wrappers belong to the backends
//! selected by `io.zig`. This module does not import either backend.

const std = @import("std");
const builtin = @import("builtin");

const io_mod = @This();
const core = @import("../core/exports.zig");
const ffi = @import("../c/exports.zig");

const api = core.api;
pub const io_c = ffi.io;

pub const Datagram = struct { payload: []const u8, address: SocketAddress };
pub const IPAddressError = error{ InvalidEndpoint, NoSpaceLeft };
pub const ReachabilityInfo = io_c.pp_reachability;
pub const SocketAddress = io_c.pp_socket_address;
pub const SocketAddressError = error{InvalidEndpoint};
pub const SocketType = api.SocketType;

pub const Side = enum {
    link,
    tun,
};

/// Resolved peer address and transport, copied by value across queue boundaries.
pub const SocketEndpoint = struct {
    address: SocketAddress,
    type: api.IPSocketType,

    pub fn init(endpoint: api.ExtendedEndpoint) SocketAddressError!SocketEndpoint {
        return .{
            .address = try socketAddress(endpoint),
            .type = endpoint.proto.socket_type,
        };
    }

    pub fn plainSocketType(self: SocketEndpoint) SocketType {
        return switch (self.type) {
            .udp, .udp4, .udp6 => .udp,
            .tcp, .tcp4, .tcp6 => .tcp,
        };
    }

    /// Returns a textual IP borrowed from buffer, for tunnel settings and logging.
    pub fn ipAddress(self: SocketEndpoint, buffer: []u8) IPAddressError!api.Address {
        const bytes = self.address.address;
        return switch (self.address.family) {
            4 => .{
                .raw = try std.fmt.bufPrint(
                    buffer,
                    "{d}.{d}.{d}.{d}",
                    .{ bytes[0], bytes[1], bytes[2], bytes[3] },
                ),
                .family = .v4,
            },
            6 => blk: {
                const ip = std.Io.net.Ip6Address.Unresolved{
                    .bytes = bytes,
                    .interface_name = null,
                };
                const text = if (self.address.scope_id == 0)
                    try std.fmt.bufPrint(buffer, "{f}", .{ip})
                else
                    try std.fmt.bufPrint(buffer, "{f}%{d}", .{ ip, self.address.scope_id });
                break :blk .{
                    .raw = text,
                    .family = .v6,
                };
            },
            else => error.InvalidEndpoint,
        };
    }
};

/// Shared readiness wake. Callers serialize access with their I/O lock;
/// wait() releases that lock while blocking and reacquires it before returning.
pub const Waiter = struct {
    pub const Error = error{WaitFailed};

    mux: io_c.pp_mux,
    pending: usize = 0,
    pollers: core.Drainer = .{},
    waking: bool = false,
    released: bool = false,
    test_wait_once: if (builtin.is_test) ?*const fn (io_c.pp_fd, bool, io_c.pp_fd) callconv(.c) c_int else void = if (builtin.is_test) null else {},

    pub fn init() ?Waiter {
        return .{ .mux = io_c.pp_mux_create(1) orelse return null };
    }

    pub fn wake(self: *Waiter) void {
        if (self.pollers.in_flight != 0 and !self.waking) {
            self.waking = true;
            _ = io_c.pp_mux_wake(self.mux);
        }
    }

    pub fn deinit(self: *Waiter) void {
        self.wake();
        self.released = true;
        self.freeIfReleased();
    }

    fn freeIfReleased(self: *Waiter) void {
        if (self.released and self.pending == 0) {
            io_c.pp_mux_free(self.mux);
            self.pollers.deinit();
            self.* = .{ .mux = null };
        }
    }

    /// A null descriptor waits only for wake. Returns true for I/O readiness.
    /// Callers must hold the same protecting lock. A caller joining
    /// an outstanding wake waits for its original pollers to drain, then returns
    /// false so the owner can recheck descriptors replaced during that wake.
    pub fn wait(self: *Waiter, fd: ?io_c.pp_fd, writing: bool, lock: *core.Mutex) Waiter.Error!bool {
        self.pending += 1;
        defer {
            self.pending -= 1;
            self.freeIfReleased();
        }
        if (self.waking) {
            // A fresh, unsignalled poller may enter before this caller resumes.
            // Only wait for the wake to drain, not for all later I/O to finish.
            while (self.waking) self.pollers.drained.wait(lock);
            return false;
        }
        self.pollers.enter();
        defer {
            self.pollers.leaveLocked();
            // Retries cannot join this cohort and keep its wake signalled.
            if (self.pollers.in_flight == 0) {
                _ = io_c.pp_mux_reset_wake(self.mux);
                self.waking = false;
            }
        }
        lock.unlock();
        defer lock.lock();
        const wait_once = if (builtin.is_test) self.test_wait_once orelse io_c.pp_mux_wait_once else io_c.pp_mux_wait_once;
        const result = wait_once(fd orelse io_c.pp_fd_invalid(), writing, io_c.pp_mux_wake_descriptor(self.mux));
        if (result < 0) return error.WaitFailed;
        return result > 0;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    Backpressure,
    /// An unconnected UDP packet failed; the socket remains usable.
    DatagramDropped,
    EndOfStream,
    InvalidAddressFamily,
    InvalidOffset,
    InvalidSocketMode,
    /// A native operation failed; the corresponding last-error code is available.
    LibcFailure,
    MissingDestination,
    WouldBlock,
};

pub const SocketOptions = struct {
    /// Used only for unconnected UDP. Enabling both prefers dual-stack, with IPv4 fallback when IPv6 is unsupported.
    ipv4: bool = true,
    ipv6: bool = true,
    port: u16 = 0,
    timeout_ms: c_int = 0,
    buf_size: c_int = 0,
    reachability: ?io_c.pp_reachability = null,
    configure: io_c.pp_socket_configure = null,
    configure_ctx: ?*anyopaque = null,
};

pub fn reachabilityNone() io_c.pp_reachability {
    var reachability = std.mem.zeroes(io_c.pp_reachability);
    reachability.reachable = false;
    return reachability;
}

/// Converts a resolved endpoint; hostnames and named IPv6 zones must be resolved first.
fn socketAddress(endpoint: api.ExtendedEndpoint) SocketAddressError!SocketAddress {
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

pub const testing = struct {
    pub fn reachable(value: bool) ReachabilityInfo {
        var result = std.mem.zeroes(ReachabilityInfo);
        result.reachable = value;
        return result;
    }
    pub const reachabilityNone = io_mod.reachabilityNone;
    pub const socketAddress = io_mod.socketAddress;
};
