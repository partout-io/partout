// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! POSIX socket implementation. Selected by io.zig on non-Windows platforms.

const std = @import("std");
const builtin = @import("builtin");
const ffi = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const io = @import("io_common.zig");
const api = core.api;
const log = core.logging;
const util = core.util;
const io_c = ffi.io;

const Error = io.Error;
const SocketOptions = io.SocketOptions;

pub const FileDescriptor = io_c.pp_fd;
pub const SocketDescriptor = io_c.pp_socket_fd;
const reachabilityNone = io.reachabilityNone;

pub fn threadEnter() error{LibcFailure}!void {}

pub fn threadExit() void {}

/// A descriptor includes:
/// - The `fd` to watch for I/O events.
/// - The `io` interface to perform reads and writes.
pub const POSIXDescriptor = struct {
    fd: FileDescriptor,
    io: POSIXInterface,

    pub fn cleanup(self: POSIXDescriptor) void {
        self.io.cleanup();
    }

    pub fn tunWrapper(self: POSIXDescriptor) ?*TunWrapper {
        return switch (self.io) {
            .tun => |tun| tun,
            else => null,
        };
    }

    pub fn localAddress(self: POSIXDescriptor) !io.SocketAddress {
        return switch (self.io) {
            .socket => |socket| socket.localAddress(),
            else => error.InvalidSocketMode,
        };
    }
};

pub const LinkDescriptor = POSIXDescriptor;
pub const TunDescriptor = POSIXDescriptor;

/// Native I/O for the closed set of POSIX wrappers. Each switch arm calls
/// the concrete wrapper directly. Tests can supply a callback-backed mock;
/// its payload is uninhabited outside test builds.
/// Wrappers must remain at a stable address until cleanup, which destroys them.
/// Each wrapper must be cleaned up exactly once.
pub const POSIXInterface = union(enum) {
    socket: *SocketWrapper,
    tun: *TunWrapper,
    mock: Mock,

    pub const Mock = if (builtin.is_test) struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            read: *const fn (*anyopaque, []u8) Error!?usize,
            write: *const fn (*anyopaque, []const u8, usize) Error!usize,
            cleanup: *const fn (*anyopaque) void,
            last_error_code: *const fn (*anyopaque) c_int,
        };
    } else noreturn;

    pub fn isUnconnected(self: POSIXInterface) bool {
        return switch (self) {
            .socket => |socket| socket.isUnconnected(),
            else => false,
        };
    }

    /// Packet I/O preserves optional endpoint metadata without exposing UDP
    /// socket details to the looper. Streams and TUN retain their byte I/O path.
    pub fn readPacket(self: POSIXInterface, buf: []u8, address: *io.SocketAddress) Error!?usize {
        return switch (self) {
            .socket => |socket| if (socket.isUnconnected())
                try socket.receiveFrom(buf, address)
            else
                socket.read(buf),
            else => self.read(buf),
        };
    }

    pub fn writePacket(self: POSIXInterface, data: []const u8, offset: usize, address: ?io.SocketAddress) Error!usize {
        return switch (self) {
            .socket => |socket| if (socket.isUnconnected())
                socket.sendTo(data, address orelse return error.MissingDestination)
            else
                socket.write(data, offset),
            else => self.write(data, offset),
        };
    }

    /// Resolve the wrapper's fd before releasing the caller's held I/O lock.
    /// The lock is reacquired before returning; no wrapper access occurs while waiting.
    pub fn waitForReadiness(self: POSIXInterface, writing: bool, waiter: *io.Waiter, io_lock: *core.Mutex) Error!bool {
        const fd = switch (self) {
            .mock => -1,
            inline else => |wrapper| wrapper.muxDescriptor() orelse return error.LibcFailure,
        };
        return waiter.wait(fd, writing, io_lock) catch error.LibcFailure;
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
    allocator: std.mem.Allocator,
    socket: io_c.pp_socket,
    remote_endpoint: ?io.SocketEndpoint = null,
    closes_on_empty_read: bool = false,
    is_closed: bool = false,

    /// Creates a connected socket (resolving hostnames in C), or one unconnected UDP socket for the requested families.
    /// A null endpoint selects unconnected UDP.
    /// Ownership transfers on successful looper attachment.
    pub fn create(
        allocator: std.mem.Allocator,
        endpoint: ?api.ExtendedEndpoint,
        options: SocketOptions,
    ) std.mem.Allocator.Error!?*SocketWrapper {
        if (endpoint == null and !options.ipv4 and !options.ipv6) return null;

        const socket_endpoint = endpoint orelse api.ExtendedEndpoint{
            .address = if (options.ipv6) "::" else "0.0.0.0",
            .proto = .init(.udp, options.port),
        };
        const socket = try open(allocator, socket_endpoint, endpoint == null, options) orelse return null;
        errdefer io_c.pp_socket_free(socket);
        const remote_endpoint: ?io.SocketEndpoint = if (endpoint) |value|
            io.SocketEndpoint.init(value) catch blk: {
                // Preserve the C resolver's selected peer without resolving again.
                var address: io.SocketAddress = undefined;
                if (!io_c.pp_socket_get_peer_address(socket, &address)) {
                    io_c.pp_socket_free(socket);
                    return null;
                }
                break :blk .{ .address = address, .type = value.proto.socket_type };
            }
        else
            null;
        const wrapper = try allocator.create(SocketWrapper);
        wrapper.* = .{
            .socket = socket,
            .remote_endpoint = remote_endpoint,
            .closes_on_empty_read = if (endpoint) |value| value.plainSocketType() == .tcp else false,
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
        endpoint: api.ExtendedEndpoint,
        unconnected: bool,
        options: SocketOptions,
    ) !?io_c.pp_socket {
        var c_address: util.TemporaryCString = .{};
        try c_address.init(allocator, endpoint.address);
        defer c_address.deinit();

        const reachability = options.reachability orelse reachabilityNone();
        log.writef(.debug, "SocketWrapper: Opening POSIX socket, protocol={s}, mode={s}, dual_stack={}", .{
            @tagName(endpoint.plainSocketType()),
            if (unconnected) "unconnected (bind)" else "connected (connect)",
            unconnected and options.ipv4 and options.ipv6,
        });
        const socket = io_c.pp_socket_open(
            c_address.ptr(),
            io.socketProto(endpoint),
            endpoint.proto.port,
            &.{
                .unconnected = unconnected,
                .dual_stack = unconnected and options.ipv4 and options.ipv6,
                .timeout_ms = options.timeout_ms,
                .reachability = &reachability,
                .configure = options.configure,
                .configure_ctx = options.configure_ctx,
            },
        ) orelse return null;

        _ = io_c.pp_socket_set_buffers(socket, options.buf_size, options.buf_size);
        return socket;
    }

    fn free(self: *SocketWrapper) void {
        if (self.is_closed) return;
        self.is_closed = true;
        io_c.pp_socket_free(self.socket);
    }

    fn nativeIO(self: *SocketWrapper) POSIXInterface {
        return .{ .socket = self };
    }

    fn isUnconnected(self: *const SocketWrapper) bool {
        return self.remote_endpoint == null;
    }

    fn read(self: *const SocketWrapper, buf: []u8) !?usize {
        if (self.isUnconnected()) return error.InvalidSocketMode;
        const read_count = io_c.pp_socket_read(self.socket, buf.ptr, buf.len, null);
        return mapReadResult(.link, read_count, self.closes_on_empty_read);
    }

    fn write(self: *const SocketWrapper, data: []const u8, offset: usize) !usize {
        if (self.isUnconnected()) return error.InvalidSocketMode;
        if (offset > data.len) return error.InvalidOffset;
        const written = io_c.pp_socket_write(self.socket, data.ptr + offset, data.len - offset, null);
        return mapWriteResult(.link, written, false);
    }

    fn cleanup(self: *SocketWrapper) void {
        self.destroy();
    }

    fn lastErrorCode(_: SocketWrapper) c_int {
        return io_c.pp_socket_last_error_binding();
    }

    fn receiveFrom(self: *SocketWrapper, buf: []u8, address: *io.SocketAddress) !usize {
        if (!self.isUnconnected()) return error.InvalidSocketMode;
        const count = io_c.pp_socket_read(self.socket, buf.ptr, buf.len, address);
        if (count == io_c.PPIOErrorWouldBlock) return error.WouldBlock;
        if (count < 0) return datagramError(false);
        return @intCast(count);
    }

    fn sendTo(self: *const SocketWrapper, data: []const u8, address: io.SocketAddress) !usize {
        if (!self.isUnconnected()) return error.InvalidSocketMode;
        if (address.family != 4 and address.family != 6) return error.InvalidAddressFamily;
        return mapWriteResult(.link, io_c.pp_socket_write(self.socket, data.ptr, data.len, &address), false) catch |err| {
            return if (err == error.LibcFailure) datagramError(true) else err;
        };
    }

    fn datagramError(writing: bool) Error {
        // Truncation and per-destination errors (including asynchronous ICMP)
        // do not invalidate a shared UDP socket or its other peers.
        return switch (io_c.pp_socket_last_error_binding()) {
            @intFromEnum(std.c.E.MSGSIZE),
            @intFromEnum(std.c.E.NETUNREACH),
            @intFromEnum(std.c.E.HOSTUNREACH),
            @intFromEnum(std.c.E.CONNREFUSED),
            @intFromEnum(std.c.E.AFNOSUPPORT),
            => error.DatagramDropped,
            // macOS reports a destination/socket family mismatch as EINVAL.
            @intFromEnum(std.c.E.INVAL) => if (writing) error.DatagramDropped else error.LibcFailure,
            else => error.LibcFailure,
        };
    }

    fn localAddress(self: *const SocketWrapper) !io.SocketAddress {
        var address: io.SocketAddress = undefined;
        if (!io_c.pp_socket_get_address(self.socket, &address)) return error.LibcFailure;
        return address;
    }

    pub fn remoteAddress(self: *const SocketWrapper) ?io.SocketAddress {
        const endpoint = self.remote_endpoint orelse return null;
        return endpoint.address;
    }

    fn muxDescriptor(self: SocketWrapper) ?io_c.pp_fd {
        const fd = io_c.pp_socket_get_watch_fd(self.socket);
        return if (io_c.pp_fd_is_valid(fd)) fd else null;
    }

    pub fn linkDescriptor(self: *SocketWrapper) LinkDescriptor {
        return .{
            .fd = io_c.pp_socket_get_watch_fd(self.socket),
            .io = self.nativeIO(),
        };
    }
};

pub const TunWrapper = struct {
    allocator: std.mem.Allocator,
    tun: io_c.pp_tun,
    is_closed: bool = false,
    test_descriptor: if (builtin.is_test) ?POSIXDescriptor else void = if (builtin.is_test) null else {},

    pub fn create(allocator: std.mem.Allocator, tun: io_c.pp_tun) std.mem.Allocator.Error!*TunWrapper {
        const self = try allocator.create(TunWrapper);
        self.* = .{ .tun = tun, .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *TunWrapper) void {
        log.write(.debug, "Destroy TunWrapper");
        self.free();
        self.allocator.destroy(self);
    }

    fn free(self: *TunWrapper) void {
        if (self.is_closed) return;
        self.is_closed = true;
        if (builtin.is_test) if (self.test_descriptor) |descriptor| {
            descriptor.cleanup();
            return;
        };
        io_c.pp_tun_free(self.tun);
    }

    fn nativeIO(self: *TunWrapper) POSIXInterface {
        return .{ .tun = self };
    }

    fn read(self: *const TunWrapper, buf: []u8) !?usize {
        if (builtin.is_test) if (self.test_descriptor) |descriptor| return descriptor.io.read(buf);
        const read_count = io_c.pp_tun_read(self.tun, buf.ptr, buf.len);
        return mapReadResult(.tun, read_count, false);
    }

    fn write(self: *const TunWrapper, data: []const u8, offset: usize) !usize {
        if (offset > data.len) return error.InvalidOffset;
        if (builtin.is_test) if (self.test_descriptor) |descriptor| return descriptor.io.write(data, offset);
        const written = io_c.pp_tun_write(self.tun, data.ptr + offset, data.len - offset);
        return mapWriteResult(.tun, written, true);
    }

    fn cleanup(self: *TunWrapper) void {
        self.destroy();
    }

    fn lastErrorCode(_: TunWrapper) c_int {
        return io_c.pp_io_last_error_binding();
    }

    pub fn muxDescriptor(self: TunWrapper) ?io_c.pp_fd {
        if (builtin.is_test) if (self.test_descriptor) |descriptor| return descriptor.fd;
        const fd = io_c.pp_tun_get_watch_fd(self.tun);
        return if (io_c.pp_fd_is_valid(fd)) fd else null;
    }

    pub fn tunDescriptor(self: *TunWrapper) !TunDescriptor {
        const fd = self.muxDescriptor() orelse return error.LibcFailure;
        if (io_c.pp_fd_set_nonblocking(fd, null) != 0) return error.LibcFailure;
        return .{
            .fd = fd,
            .io = self.nativeIO(),
        };
    }
};

pub fn mapReadResult(_: io.Side, result: c_int, closes_on_empty_read: bool) !?usize {
    if (result == io_c.PPIOErrorWouldBlock) return error.WouldBlock;
    if (result < 0) return error.LibcFailure;
    if (result == 0) {
        if (closes_on_empty_read) return error.EndOfStream;
        return null;
    }
    return @intCast(result);
}

pub fn mapWriteResult(_: io.Side, result: c_int, comptime maps_no_space: bool) !usize {
    if (result == io_c.PPIOErrorWouldBlock) return error.WouldBlock;
    if (result == io_c.PPIOErrorNoBufs) return error.Backpressure;
    if (maps_no_space and result == io_c.PPIOErrorNoSpace) return error.Backpressure;
    if (result < 0) return error.LibcFailure;
    return @intCast(result);
}

/// A readiness-driven thread supplies borrowed input; writes submit directly.
/// No thread starts until a receiver is registered. Removal wakes and joins it.
pub fn CallbackTransport(comptime DescriptorType: type) type {
    return struct {
        const Self = @This();
        pub const Descriptor = DescriptorType;
        pub const OnReceive = io.PacketReceiveCallback;
        pub const WriteResult = io.PacketWriteResult;

        allocator: std.mem.Allocator,
        descriptor: Descriptor,
        io_lock: core.Mutex = .{},
        readiness: io.Waiter,
        receive_thread: ?std.Thread = null,
        on_receive: OnReceive = null,
        receive_context: ?*anyopaque = null,
        stop_receiving: bool = false,
        writes_stopped: bool = false,

        /// Takes descriptor ownership on entry, including allocation failure.
        pub fn create(allocator: std.mem.Allocator, descriptor: Descriptor) std.mem.Allocator.Error!*Self {
            errdefer releaseDescriptor(descriptor);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .descriptor = descriptor,
                .readiness = io.Waiter.init() orelse return error.OutOfMemory,
            };
            return self;
        }

        pub fn cleanup(self: *Self) void {
            self.stopWrites();
            self.setOnReceive(null, null) catch unreachable;
            self.readiness.deinit();
            self.io_lock.deinit();
            releaseDescriptor(self.descriptor);
            self.allocator.destroy(self);
        }

        pub fn setOnReceive(self: *Self, callback: OnReceive, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
            if (callback == null) {
                self.io_lock.lock();
                self.stop_receiving = true;
                self.readiness.wake();
                self.io_lock.unlock();
                if (self.receive_thread) |thread| thread.join();
                self.receive_thread = null;
                self.on_receive = null;
                self.receive_context = null;
                return;
            }
            if (self.receive_thread != null) return error.ReceiveSetupFailed;
            self.on_receive = callback;
            self.receive_context = context;
            self.stop_receiving = false;
            self.receive_thread = std.Thread.spawn(.{}, receivePackets, .{self}) catch {
                self.on_receive = null;
                self.receive_context = null;
                return error.ReceiveSetupFailed;
            };
        }

        pub fn stopWrites(self: *Self) void {
            self.io_lock.lock();
            self.writes_stopped = true;
            self.io_lock.unlock();
        }

        pub fn write(self: *Self, bytes: []const u8, destination: ?io.SocketAddress) WriteResult {
            self.io_lock.lock();
            defer self.io_lock.unlock();
            if (self.writes_stopped) return .failed;
            const descriptor = switch (self.descriptor) {
                inline else => |descriptor| descriptor,
            };
            const size = descriptor.io.writePacket(bytes, 0, destination) catch |err| return switch (err) {
                error.WouldBlock, error.Backpressure => .again,
                error.DatagramDropped => if (self.descriptor == .link) .dropped else .failed,
                else => .failed,
            };
            return if (size == bytes.len) .ok else .failed;
        }

        fn receivePackets(self: *Self) void {
            const descriptor = switch (self.descriptor) {
                inline else => |descriptor| descriptor,
            };
            var buffer: [65535]u8 = undefined;
            while (true) {
                self.io_lock.lock();
                if (self.stop_receiving) {
                    self.io_lock.unlock();
                    return;
                }
                var address = std.mem.zeroes(io.SocketAddress);
                const size = descriptor.io.readPacket(&buffer, &address) catch |err| {
                    if (err == error.DatagramDropped) {
                        self.io_lock.unlock();
                        continue;
                    }
                    if (err == error.WouldBlock) {
                        _ = descriptor.io.waitForReadiness(false, &self.readiness, &self.io_lock) catch {
                            self.io_lock.unlock();
                            self.reportReceiveFailure();
                            return;
                        };
                        self.io_lock.unlock();
                        continue;
                    }
                    self.io_lock.unlock();
                    self.reportReceiveFailure();
                    return;
                } orelse {
                    self.io_lock.unlock();
                    self.reportReceiveFailure();
                    return;
                };
                if (self.descriptor == .link and descriptor.io == .socket and !descriptor.io.isUnconnected())
                    address = descriptor.io.socket.remoteAddress() orelse address;
                self.io_lock.unlock();
                if (!self.on_receive.?(self.receive_context, &buffer, size, if (self.descriptor == .link) &address else null, 0)) return;
            }
        }

        fn reportReceiveFailure(self: *Self) void {
            self.io_lock.lock();
            const stopping = self.stop_receiving;
            self.io_lock.unlock();
            if (!stopping) _ = self.on_receive.?(self.receive_context, null, 0, null, -1);
        }

        pub fn releaseDescriptor(descriptor: Descriptor) void {
            switch (descriptor) {
                inline else => |value| value.cleanup(),
            }
        }
    };
}
