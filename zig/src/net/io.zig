// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Wrappers around the C code for sockets and tun devices
//! for each supported platform. Some platforms may require
//! an additional socket configuration step, for which a specific
//! `ConfigureSocket` callback can be supplied.
//!
//! Here we also map the native types for file (`FileDescriptor`)
//! and socket descriptors (`SocketDescriptor`) as they may vary
//! across platforms. Make sure to use the symbolic types wherever
//! files and sockets are treated.
//!
//! Eventually, both socket and tun are exposed via the generic
//! `IOInterface`.

const std = @import("std");

const io_mod = @This();
const c_mod = @import("../c/exports.zig");
const core = @import("../core/exports.zig");

const api = core.api;
pub const c = c_mod.io;
const log = core.logging;
const util = core.util;

pub const FileDescriptor = c.pp_fd;
pub const ReachabilityInfo = c.pp_reachability;
pub const SocketDescriptor = c.pp_socket_fd;

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
    reachability: ?c.pp_reachability = null,
    configure: c.pp_socket_configure = null,
    configure_ctx: ?*anyopaque = null,

    pub fn closesOnEmptyRead(self: *const SocketOptions) bool {
        return self.endpoint.plainSocketType() == .tcp;
    }
};

pub const SocketWrapper = struct {
    socket: c.pp_socket,
    options: SocketOptions,
    closes_on_empty_read: bool,
    is_closed: bool = false,
    owner_allocator: ?std.mem.Allocator = null,

    pub fn init(
        allocator: std.mem.Allocator,
        options: SocketOptions,
    ) error{OutOfMemory}!?SocketWrapper {
        const socket = try open(allocator, options) orelse return null;
        return .{
            .socket = socket,
            .options = options,
            .closes_on_empty_read = options.closesOnEmptyRead(),
        };
    }

    pub fn create(
        allocator: std.mem.Allocator,
        options: SocketOptions,
    ) error{OutOfMemory}!?*SocketWrapper {
        const wrapper = try allocator.create(SocketWrapper);
        errdefer allocator.destroy(wrapper);
        wrapper.* = try init(allocator, options) orelse {
            allocator.destroy(wrapper);
            return null;
        };
        wrapper.owner_allocator = allocator;
        return wrapper;
    }

    pub fn deinit(self: *const SocketWrapper) void {
        log.write(.debug, "Deinit SocketWrapper");
        self.cleanup();
    }

    fn open(
        allocator: std.mem.Allocator,
        options: SocketOptions,
    ) error{OutOfMemory}!?c.pp_socket {
        var c_address: util.TemporaryCString = .{};
        try c_address.init(allocator, options.endpoint.address);
        defer c_address.deinit();

        const reachability = options.reachability orelse reachabilityNone();
        const socket = c.pp_socket_open(
            c_address.ptr(),
            socketProto(options.endpoint),
            options.endpoint.proto.port,
            false,
            options.timeout_ms,
            &reachability,
            options.configure,
            options.configure_ctx,
        ) orelse return null;

        _ = c.pp_socket_set_buffers(socket, options.buf_size, options.buf_size);
        return socket;
    }

    pub fn nativeIO(self: *SocketWrapper) IOInterface {
        return .{
            .ptr = self,
            .vtable = if (self.owner_allocator != null) &owned_socket_vtable else &socket_vtable,
        };
    }

    pub fn setEventMask(self: *const SocketWrapper, readable: bool, writable: bool) Error!void {
        if (!c.pp_socket_set_event_mask(self.socket, readable, writable)) return error.LibcFailure;
    }

    pub fn resetEvents(self: *const SocketWrapper) Error!void {
        if (!c.pp_socket_reset_events(self.socket)) return error.LibcFailure;
    }

    pub fn read(self: *const SocketWrapper, buf: []u8) Error!?usize {
        const read_count = c.pp_socket_read(self.socket, buf.ptr, buf.len);
        return mapReadResult(.link, read_count, self.closes_on_empty_read);
    }

    pub fn write(self: *const SocketWrapper, data: []const u8, offset: usize) Error!usize {
        if (offset > data.len) return error.LibcFailure;
        const written = c.pp_socket_write(self.socket, data.ptr + offset, data.len - offset);
        return mapWriteResult(.link, written, false);
    }

    pub fn cleanup(self: *SocketWrapper) void {
        if (self.is_closed) return;
        self.is_closed = true;
        c.pp_socket_free_and_close(self.socket, true);
    }

    pub fn close(self: *const SocketWrapper) void {
        if (self.is_closed) return;
        c.pp_socket_close(self.socket);
    }

    pub fn muxDescriptor(self: SocketWrapper) ?FileDescriptor {
        const fd = c.pp_socket_get_watch_fd(self.socket);
        return if (c.pp_fd_is_valid(fd)) fd else null;
    }

    pub fn socketDescriptor(self: SocketWrapper) SocketDescriptor {
        return c.pp_socket_get_fd(self.socket);
    }

    pub fn remoteAddress(self: SocketWrapper) api.Address {
        return api.Address.parseRaw(self.options.endpoint.address).?;
    }

    pub fn remoteProtocol(self: SocketWrapper) api.EndpointProtocol {
        return self.options.endpoint.proto;
    }

    pub fn isReliable(self: SocketWrapper) bool {
        return self.options.endpoint.plainSocketType() == .tcp;
    }

    pub fn lastErrorCode(_: SocketWrapper) c_int {
        return c.pp_socket_last_error();
    }
};

pub const TunWrapper = struct {
    tun: c.pp_tun,
    is_closed: bool = false,

    pub fn init(tun: c.pp_tun) TunWrapper {
        return .{ .tun = tun };
    }

    pub fn deinit(self: *TunWrapper) void {
        log.write(.debug, "Deinit TunWrapper");
        self.cleanup();
    }

    fn open(
        allocator: std.mem.Allocator,
        uuid: []const u8,
    ) error{OutOfMemory}!?c.pp_tun {
        if (!@hasDecl(c, "pp_tun_open")) return null;
        var c_uuid: util.TemporaryCString = .{};
        try c_uuid.init(allocator, uuid);
        defer c_uuid.deinit();
        return c.pp_tun_open(c_uuid.ptr());
    }

    pub fn nativeIO(self: *const TunWrapper) IOInterface {
        return .{
            .ptr = self,
            .vtable = &tun_vtable,
        };
    }

    pub fn setEventMask(_: *TunWrapper, _: bool, _: bool) Error!void {}

    pub fn resetEvents(_: *TunWrapper) Error!void {}

    pub fn read(self: *const TunWrapper, buf: []u8) Error!?usize {
        const read_count = c.pp_tun_read(self.tun, buf.ptr, buf.len);
        return mapReadResult(.tun, read_count, false);
    }

    pub fn write(self: *const TunWrapper, data: []const u8, offset: usize) Error!usize {
        if (offset > data.len) return error.LibcFailure;
        const written = c.pp_tun_write(self.tun, data.ptr + offset, data.len - offset);
        return mapWriteResult(.tun, written, true);
    }

    pub fn cleanup(self: *TunWrapper) void {
        if (self.is_closed) return;
        self.is_closed = true;
        c.pp_tun_free_and_close(self.tun, true);
    }

    pub fn muxDescriptor(self: TunWrapper) ?c.pp_fd {
        const fd = c.pp_tun_get_watch_fd(self.tun);
        return if (c.pp_fd_is_valid(fd)) fd else null;
    }

    pub fn name(self: TunWrapper) ?[]const u8 {
        const c_name = c.pp_tun_name(self.tun) orelse return null;
        return std.mem.span(c_name);
    }

    pub fn lastErrorCode(_: TunWrapper) c_int {
        return c.pp_io_last_error();
    }
};

fn socketProto(endpoint: api.ExtendedEndpoint) c.pp_socket_proto {
    return switch (endpoint.plainSocketType()) {
        .udp => c.PPSocketProtoUDP,
        .tcp => c.PPSocketProtoTCP,
    };
}

const socket_vtable = IOInterface.VTable{
    .set_event_mask = socketSetEventMask,
    .reset_events = socketResetEvents,
    .read = socketRead,
    .write = socketWrite,
    .cleanup = socketCleanup,
    .last_error_code = socketLastErrorCode,
};

fn socketSetEventMask(ptr: *anyopaque, read: bool, write: bool) Error!void {
    const self: *SocketWrapper = @ptrCast(@alignCast(ptr));
    return self.setEventMask(read, write);
}

fn socketResetEvents(ptr: *anyopaque) Error!void {
    const self: *SocketWrapper = @ptrCast(@alignCast(ptr));
    return self.resetEvents();
}

fn socketRead(ptr: *anyopaque, buf: []u8) Error!?usize {
    const self: *SocketWrapper = @ptrCast(@alignCast(ptr));
    return self.read(buf);
}

fn socketWrite(ptr: *anyopaque, data: []const u8, offset: usize) Error!usize {
    const self: *SocketWrapper = @ptrCast(@alignCast(ptr));
    return self.write(data, offset);
}

fn socketCleanup(ptr: *anyopaque) void {
    const self: *SocketWrapper = @ptrCast(@alignCast(ptr));
    self.cleanup();
}

fn socketLastErrorCode(ptr: *anyopaque) c_int {
    const self: *SocketWrapper = @ptrCast(@alignCast(ptr));
    return self.lastErrorCode();
}

const owned_socket_vtable = IOInterface.VTable{
    .set_event_mask = socketSetEventMask,
    .reset_events = socketResetEvents,
    .read = socketRead,
    .write = socketWrite,
    .cleanup = ownedSocketCleanup,
    .last_error_code = socketLastErrorCode,
};

fn ownedSocketCleanup(ptr: *anyopaque) void {
    const self: *SocketWrapper = @ptrCast(@alignCast(ptr));
    const allocator = self.owner_allocator orelse {
        self.cleanup();
        return;
    };
    log.write(.debug, "Deinit SocketWrapper");
    self.cleanup();
    allocator.destroy(self);
}

const tun_vtable = IOInterface.VTable{
    .set_event_mask = tunSetEventMask,
    .reset_events = tunResetEvents,
    .read = tunRead,
    .write = tunWrite,
    .cleanup = tunCleanup,
    .last_error_code = tunLastErrorCode,
};

fn tunSetEventMask(ptr: *anyopaque, read: bool, write: bool) Error!void {
    const self: *TunWrapper = @ptrCast(@alignCast(ptr));
    return self.setEventMask(read, write);
}

fn tunResetEvents(ptr: *anyopaque) Error!void {
    const self: *TunWrapper = @ptrCast(@alignCast(ptr));
    return self.resetEvents();
}

fn tunRead(ptr: *anyopaque, buf: []u8) Error!?usize {
    const self: *TunWrapper = @ptrCast(@alignCast(ptr));
    return self.read(buf);
}

fn tunWrite(ptr: *anyopaque, data: []const u8, offset: usize) Error!usize {
    const self: *TunWrapper = @ptrCast(@alignCast(ptr));
    return self.write(data, offset);
}

fn tunCleanup(ptr: *anyopaque) void {
    const self: *TunWrapper = @ptrCast(@alignCast(ptr));
    self.cleanup();
}

fn tunLastErrorCode(ptr: *anyopaque) c_int {
    const self: *TunWrapper = @ptrCast(@alignCast(ptr));
    return self.lastErrorCode();
}

// Shared functions

fn reachabilityNone() c.pp_reachability {
    var reachability = std.mem.zeroes(c.pp_reachability);
    reachability.reachable = false;
    return reachability;
}

fn mapReadResult(_: Side, result: c_int, closes_on_empty_read: bool) Error!?usize {
    if (result == c.PPIOErrorWouldBlock) return error.WouldBlock;
    if (result < 0) return error.LibcFailure;
    if (result == 0) {
        if (closes_on_empty_read) return error.EndOfStream;
        return null;
    }
    return @intCast(result);
}

fn mapWriteResult(_: Side, result: c_int, comptime maps_no_space: bool) Error!usize {
    if (result == c.PPIOErrorWouldBlock) return error.WouldBlock;
    if (result == c.PPIOErrorNoBufs) return error.Backpressure;
    if (maps_no_space and result == c.PPIOErrorNoSpace) return error.Backpressure;
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
