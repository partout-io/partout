// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Shared interfaces and options for sockets and tun devices
//! across supported platforms. Some platforms may require
//! an additional socket configuration step, for which a specific
//! configuration callback can be supplied through `SocketOptions`.
//!
//! Here we also map the native types for file (`FileDescriptor`)
//! and socket descriptors (`SocketDescriptor`) as they may vary
//! across platforms. Make sure to use the symbolic types wherever
//! files and sockets are treated.
//!
//! Both socket and tun are exposed via the generic `IOInterface`.
//! Their implementations live in `io_posix.zig` and `io_windows.zig`,
//! selected at compile time by `io.zig`. This module holds only
//! the shared types and result mapping, without importing either backend.

const std = @import("std");

const io_mod = @This();
const ffi = @import("../c/exports.zig");
const core = @import("../core/exports.zig");

const api = core.api;
pub const io_c = ffi.io;

pub const FileDescriptor = io_c.pp_fd;
pub const ReachabilityInfo = io_c.pp_reachability;
pub const SocketDescriptor = io_c.pp_socket_fd;

pub const Side = enum {
    link,
    tun,
};

pub const Error = error{
    WouldBlock,
    Backpressure,
    EndOfStream,
    LibcFailure,
    OutOfMemory,
};

pub const IOInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        set_event_mask: *const fn (*anyopaque, bool, bool) Error!void,
        reset_events: *const fn (*anyopaque) Error!void,
        read: *const fn (*anyopaque, []u8) Error!?usize,
        write: *const fn (*anyopaque, []const u8, usize) Error!usize,
        cleanup: *const fn (*anyopaque) void,
        last_error_code: *const fn (*anyopaque) c_int,
    };

    pub fn setEventMask(self: IOInterface, readable: bool, writable: bool) Error!void {
        return self.vtable.set_event_mask(self.ptr, readable, writable);
    }

    pub fn resetEvents(self: IOInterface) Error!void {
        return self.vtable.reset_events(self.ptr);
    }

    pub fn read(self: IOInterface, buf: []u8) Error!?usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn write(self: IOInterface, data: []const u8, offset: usize) Error!usize {
        return self.vtable.write(self.ptr, data, offset);
    }

    pub fn cleanup(self: IOInterface) void {
        self.vtable.cleanup(self.ptr);
    }

    pub fn lastErrorCode(self: IOInterface) c_int {
        return self.vtable.last_error_code(self.ptr);
    }
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

// Shared functions

pub fn reachabilityNone() io_c.pp_reachability {
    var reachability = std.mem.zeroes(io_c.pp_reachability);
    reachability.reachable = false;
    return reachability;
}

pub fn mapReadResult(_: Side, result: c_int, closes_on_empty_read: bool) Error!?usize {
    if (result == io_c.PPIOErrorWouldBlock) return error.WouldBlock;
    if (result < 0) return error.LibcFailure;
    if (result == 0) {
        if (closes_on_empty_read) return error.EndOfStream;
        return null;
    }
    return @intCast(result);
}

pub fn mapWriteResult(_: Side, result: c_int, comptime maps_no_space: bool) Error!usize {
    if (result == io_c.PPIOErrorWouldBlock) return error.WouldBlock;
    if (result == io_c.PPIOErrorNoBufs) return error.Backpressure;
    if (maps_no_space and result == io_c.PPIOErrorNoSpace) return error.Backpressure;
    if (result < 0) return error.LibcFailure;
    return @intCast(result);
}

pub const testing = struct {
    pub fn reachable(value: bool) ReachabilityInfo {
        var result = std.mem.zeroes(ReachabilityInfo);
        result.reachable = value;
        return result;
    }
    pub const reachabilityNone = io_mod.reachabilityNone;
    pub const mapReadResult = io_mod.mapReadResult;
    pub const mapWriteResult = io_mod.mapWriteResult;

    pub fn socketOptions(observer: anytype, timeout_ms: c_int) SocketOptions {
        return observer.socketOptions(timeout_ms);
    }
};
