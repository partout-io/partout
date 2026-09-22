// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! POSIX socket implementation. Selected by io.zig on non-Windows platforms.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/exports.zig");
const io = @import("io_common.zig");
const api = core.api;
const log = core.logging;
const util = core.util;
const io_c = io.io_c;

const Error = io.Error;
const SocketOptions = io.SocketOptions;

pub const FileDescriptor = io_c.pp_fd;
pub const SocketDescriptor = io_c.pp_socket_fd;
const reachabilityNone = io.reachabilityNone;

/// A descriptor includes:
/// - The `fd` to watch for I/O events.
/// - The `io` interface to perform reads and writes.
pub const POSIXDescriptor = struct {
    fd: FileDescriptor,
    io: POSIXInterface,

    pub fn cleanup(self: POSIXDescriptor) void {
        self.io.cleanup();
    }
};

pub const LinkDescriptor = POSIXDescriptor;
pub const TunDescriptor = POSIXDescriptor;

/// Native I/O for the closed set of POSIX wrappers. Each switch arm calls
/// the concrete wrapper directly. Tests can supply a callback-backed mock;
/// its payload is uninhabited outside test builds.
/// Wrappers must remain at a stable address until cleanup. Socket wrappers
/// are also destroyed and must be cleaned up exactly once.
pub const POSIXInterface = union(enum) {
    socket: *SocketWrapper,
    tun: *TunWrapper,
    mock: Mock,

    pub const Mock = if (builtin.is_test) struct {
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
    } else noreturn;

    pub fn setEventMask(self: POSIXInterface, readable: bool, writable: bool) Error!void {
        return switch (self) {
            .mock => |mock| if (builtin.is_test) mock.vtable.set_event_mask(mock.ptr, readable, writable) else unreachable,
            inline else => |wrapper| wrapper.setEventMask(readable, writable),
        };
    }

    pub fn resetEvents(self: POSIXInterface) Error!void {
        return switch (self) {
            .mock => |mock| if (builtin.is_test) mock.vtable.reset_events(mock.ptr) else unreachable,
            inline else => |wrapper| wrapper.resetEvents(),
        };
    }

    pub fn read(self: POSIXInterface, buf: []u8) Error!?usize {
        return switch (self) {
            .mock => |mock| if (builtin.is_test) mock.vtable.read(mock.ptr, buf) else unreachable,
            inline else => |wrapper| wrapper.read(buf),
        };
    }

    pub fn write(self: POSIXInterface, data: []const u8, offset: usize) Error!usize {
        return switch (self) {
            .mock => |mock| if (builtin.is_test) mock.vtable.write(mock.ptr, data, offset) else unreachable,
            inline else => |wrapper| wrapper.write(data, offset),
        };
    }

    pub fn cleanup(self: POSIXInterface) void {
        switch (self) {
            .mock => |mock| if (builtin.is_test) mock.vtable.cleanup(mock.ptr) else unreachable,
            inline else => |wrapper| wrapper.cleanup(),
        }
    }

    pub fn lastErrorCode(self: POSIXInterface) c_int {
        return switch (self) {
            .mock => |mock| if (builtin.is_test) mock.vtable.last_error_code(mock.ptr) else unreachable,
            inline else => |wrapper| wrapper.lastErrorCode(),
        };
    }
};

pub const SocketWrapper = struct {
    socket: io_c.pp_socket,
    options: SocketOptions,
    closes_on_empty_read: bool,
    is_closed: bool = false,
    allocator: std.mem.Allocator,

    pub fn create(
        allocator: std.mem.Allocator,
        options: SocketOptions,
    ) std.mem.Allocator.Error!?*SocketWrapper {
        const wrapper = try allocator.create(SocketWrapper);
        errdefer allocator.destroy(wrapper);
        const socket = try open(allocator, options) orelse {
            allocator.destroy(wrapper);
            return null;
        };
        wrapper.* = .{
            .socket = socket,
            .options = options,
            .closes_on_empty_read = options.closesOnEmptyRead(),
            .allocator = allocator,
        };
        return wrapper;
    }

    pub fn destroy(self: *SocketWrapper) void {
        log.write(.debug, "Destroy SocketWrapper");
        self.free();
        self.allocator.destroy(self);
    }

    fn open(
        allocator: std.mem.Allocator,
        options: SocketOptions,
    ) error{OutOfMemory}!?io_c.pp_socket {
        var c_address: util.TemporaryCString = .{};
        try c_address.init(allocator, options.endpoint.address);
        defer c_address.deinit();

        const reachability = options.reachability orelse reachabilityNone();
        const socket = io_c.pp_socket_open(
            c_address.ptr(),
            socketProto(options.endpoint),
            options.endpoint.proto.port,
            false,
            options.timeout_ms,
            &reachability,
            options.configure,
            options.configure_ctx,
        ) orelse return null;

        _ = io_c.pp_socket_set_buffers(socket, options.buf_size, options.buf_size);
        return socket;
    }

    fn nativeIO(self: *SocketWrapper) POSIXInterface {
        return .{ .socket = self };
    }

    fn setEventMask(self: *const SocketWrapper, readable: bool, writable: bool) Error!void {
        if (!io_c.pp_socket_set_event_mask(self.socket, readable, writable)) return error.LibcFailure;
    }

    fn resetEvents(self: *const SocketWrapper) Error!void {
        if (!io_c.pp_socket_reset_events(self.socket)) return error.LibcFailure;
    }

    fn read(self: *const SocketWrapper, buf: []u8) Error!?usize {
        const read_count = io_c.pp_socket_read(self.socket, buf.ptr, buf.len);
        return mapReadResult(.link, read_count, self.closes_on_empty_read);
    }

    fn write(self: *const SocketWrapper, data: []const u8, offset: usize) Error!usize {
        if (offset > data.len) return error.LibcFailure;
        const written = io_c.pp_socket_write(self.socket, data.ptr + offset, data.len - offset);
        return mapWriteResult(.link, written, false);
    }

    /// Releases native I/O and the wrapper itself.
    fn cleanup(self: *SocketWrapper) void {
        self.destroy();
    }

    fn free(self: *SocketWrapper) void {
        if (self.is_closed) return;
        self.is_closed = true;
        io_c.pp_socket_free(self.socket);
    }

    fn muxDescriptor(self: SocketWrapper) ?FileDescriptor {
        const fd = io_c.pp_socket_get_watch_fd(self.socket);
        return if (io_c.pp_fd_is_valid(fd)) fd else null;
    }

    fn socketDescriptor(self: SocketWrapper) SocketDescriptor {
        return io_c.pp_socket_get_fd(self.socket);
    }

    pub fn remoteAddress(self: SocketWrapper) ?api.Address {
        return api.Address.parseRaw(self.options.endpoint.address);
    }

    fn remoteProtocol(self: SocketWrapper) api.EndpointProtocol {
        return self.options.endpoint.proto;
    }

    fn isReliable(self: SocketWrapper) bool {
        return self.options.endpoint.plainSocketType() == .tcp;
    }

    fn lastErrorCode(_: SocketWrapper) c_int {
        return io_c.pp_socket_last_error_binding();
    }

    pub fn linkDescriptor(self: *SocketWrapper) LinkDescriptor {
        return .{
            .fd = io_c.pp_socket_get_watch_fd(self.socket),
            .io = self.nativeIO(),
        };
    }
};

fn socketProto(endpoint: api.ExtendedEndpoint) io_c.pp_socket_proto {
    return switch (endpoint.plainSocketType()) {
        .udp => io_c.PPSocketProtoUDP,
        .tcp => io_c.PPSocketProtoTCP,
    };
}

pub const TunWrapper = struct {
    tun: io_c.pp_tun,
    is_closed: bool = false,

    pub fn init(tun: io_c.pp_tun) TunWrapper {
        return .{ .tun = tun };
    }

    pub fn deinit(self: *TunWrapper) void {
        log.write(.debug, "Deinit TunWrapper");
        self.free();
    }

    fn open(
        allocator: std.mem.Allocator,
        uuid: []const u8,
    ) error{OutOfMemory}!?io_c.pp_tun {
        if (!@hasDecl(io_c, "pp_tun_open")) return null;
        var c_uuid: util.TemporaryCString = .{};
        try c_uuid.init(allocator, uuid);
        defer c_uuid.deinit();
        return io_c.pp_tun_open(c_uuid.ptr());
    }

    // FIXME: ###, Drop pub after v2
    pub fn nativeIO(self: *TunWrapper) POSIXInterface {
        return .{ .tun = self };
    }

    fn setEventMask(_: *TunWrapper, _: bool, _: bool) Error!void {}

    fn resetEvents(_: *TunWrapper) Error!void {}

    fn read(self: *const TunWrapper, buf: []u8) Error!?usize {
        const read_count = io_c.pp_tun_read(self.tun, buf.ptr, buf.len);
        return mapReadResult(.tun, read_count, false);
    }

    fn write(self: *const TunWrapper, data: []const u8, offset: usize) Error!usize {
        if (offset > data.len) return error.LibcFailure;
        const written = io_c.pp_tun_write(self.tun, data.ptr + offset, data.len - offset);
        return mapWriteResult(.tun, written, true);
    }

    fn cleanup(self: *TunWrapper) void {
        self.free();
    }

    fn free(self: *TunWrapper) void {
        if (self.is_closed) return;
        self.is_closed = true;
        io_c.pp_tun_free(self.tun);
    }

    pub fn muxDescriptor(self: TunWrapper) ?io_c.pp_fd {
        const fd = io_c.pp_tun_get_watch_fd(self.tun);
        return if (io_c.pp_fd_is_valid(fd)) fd else null;
    }

    pub fn name(self: TunWrapper) ?[]const u8 {
        const tun = self.tun orelse return null;
        const c_name = io_c.pp_tun_name(tun) orelse return null;
        return std.mem.span(c_name);
    }

    fn lastErrorCode(_: TunWrapper) c_int {
        return io_c.pp_io_last_error_binding();
    }

    pub fn tunDescriptor(self: *TunWrapper) TunDescriptor {
        return .{
            .fd = io_c.pp_tun_get_watch_fd(self.tun),
            .io = self.nativeIO(),
        };
    }
};

pub fn mapReadResult(_: io.Side, result: c_int, closes_on_empty_read: bool) Error!?usize {
    if (result == io_c.PPIOErrorWouldBlock) return error.WouldBlock;
    if (result < 0) return error.LibcFailure;
    if (result == 0) {
        if (closes_on_empty_read) return error.EndOfStream;
        return null;
    }
    return @intCast(result);
}

pub fn mapWriteResult(_: io.Side, result: c_int, comptime maps_no_space: bool) Error!usize {
    if (result == io_c.PPIOErrorWouldBlock) return error.WouldBlock;
    if (result == io_c.PPIOErrorNoBufs) return error.Backpressure;
    if (maps_no_space and result == io_c.PPIOErrorNoSpace) return error.Backpressure;
    if (result < 0) return error.LibcFailure;
    return @intCast(result);
}
