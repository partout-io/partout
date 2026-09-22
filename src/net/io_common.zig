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

pub const ReachabilityInfo = io_c.pp_reachability;

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
    endpoint: api.ExtendedEndpoint,
    timeout_ms: c_int,
    buf_size: c_int,
    reachability: ?io_c.pp_reachability = null,
    configure: io_c.pp_socket_configure = null,
    configure_ctx: ?*anyopaque = null,

    pub fn closesOnEmptyRead(self: *const SocketOptions) bool {
        return self.endpoint.plainSocketType() == .tcp;
    }
};

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
