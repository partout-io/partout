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

/// Optional UDP batching for looper v2. A null read/write result selects
/// scalar I/O; platform support and socket eligibility stay inside this adapter.
pub const UDPBatch = struct {
    const supported = builtin.os.tag == .linux;
    backend: if (supported) ?LinuxUDPBatch else void = if (supported) null else {},

    pub fn init(descriptor: LinkDescriptor) UDPBatch {
        if (comptime !supported) return .{};
        if (!descriptor.io.isUnconnected()) return .{};
        const address = descriptor.localAddress() catch return .{};
        return .{ .backend = LinuxUDPBatch.init(descriptor.fd, address.family) };
    }

    pub fn write(self: *UDPBatch, packets: []const []const u8, destination: ?io.SocketAddress) ?usize {
        if (comptime !supported) return null;
        const backend = if (self.backend) |*value| value else return null;
        return backend.write(packets, destination orelse return null);
    }

    pub fn read(self: *UDPBatch, buffers: []io.ReadBuffer, max_bytes: usize) ?usize {
        if (comptime !supported) return null;
        const backend = if (self.backend) |*value| value else return null;
        return backend.read(buffers, max_bytes);
    }
};

const LinuxUDPBatch = struct {
    const linux = std.os.linux;

    fd: i32,
    dual_stack: bool,
    can_read: bool = true,
    can_write: bool = true,
    const batch_size = 16;
    const max_datagram = 65535;
    const mapped_prefix = [_]u8{0} ** 10 ++ .{ 0xff, 0xff };

    pub fn init(fd: i32, family: u8) ?LinuxUDPBatch {
        var v6_only: c_int = 1;
        if (family == 6) {
            var len: u32 = @sizeOf(c_int);
            if (linux.errno(linux.getsockopt(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, std.mem.asBytes(&v6_only), &len)) != .SUCCESS) return null;
        }
        return .{ .fd = fd, .dual_stack = family == 6 and v6_only == 0 };
    }

    pub fn write(self: *LinuxUDPBatch, packets: []const []const u8, destination: io.SocketAddress) ?usize {
        if (!self.can_write or packets.len < 2) return null;
        var address: linux.sockaddr.in6 = undefined;
        const address_len = nativeAddress(&address, self.dual_stack, destination) orelse return null;
        var messages: [batch_size]linux.mmsghdr = undefined;
        var vectors: [batch_size]std.posix.iovec = undefined;
        const count = @min(packets.len, batch_size);
        for (packets[0..count], 0..) |packet, i| {
            vectors[i] = .{ .base = @constCast(packet.ptr), .len = packet.len };
            messages[i] = std.mem.zeroes(linux.mmsghdr);
            messages[i].hdr = .{ .name = @ptrCast(&address), .namelen = address_len, .iov = @ptrCast(&vectors[i]), .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
        }
        while (true) {
            const result = linux.sendmmsg(self.fd, &messages, @intCast(count), linux.MSG.DONTWAIT);
            switch (linux.errno(result)) {
                .SUCCESS => return result,
                .INTR => continue,
                .NOSYS, .OPNOTSUPP, .PERM => self.can_write = false,
                else => {},
            }
            return null; // Scalar I/O retains its error handling and tracing.
        }
    }

    pub fn read(self: *LinuxUDPBatch, buffers: []io.ReadBuffer, max_bytes: usize) ?usize {
        if (!self.can_read or buffers.len < 2) return null;
        // Full UDP storage guarantees no truncation within a batch. Smaller
        // loans use the scalar path, which discards oversized packets in place.
        for (buffers) |buffer| if (buffer.data.len < max_datagram) return null;
        var messages: [batch_size]linux.mmsghdr = undefined;
        var vectors: [batch_size]std.posix.iovec = undefined;
        var addresses: [batch_size]linux.sockaddr.in6 = undefined;
        var received: usize = 0;
        var bytes: usize = 0;
        while (received < buffers.len) {
            // Respect the byte budget even for maximum-size datagrams. Like
            // scalar reads, always permit one packet to make forward progress.
            const count = @min(buffers.len - received, batch_size, @max(1, (max_bytes -| bytes) / max_datagram));
            for (buffers[received..][0..count], 0..) |buffer, i| {
                vectors[i] = .{ .base = buffer.data.ptr, .len = max_datagram };
                messages[i] = std.mem.zeroes(linux.mmsghdr);
                messages[i].hdr = .{ .name = @ptrCast(&addresses[i]), .namelen = @sizeOf(linux.sockaddr.in6), .iov = @ptrCast(&vectors[i]), .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            }
            const result = linux.recvmmsg(self.fd, &messages, @intCast(count), linux.MSG.DONTWAIT, null);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => |err| {
                    if (err == .NOSYS or err == .OPNOTSUPP or err == .PERM) self.can_read = false;
                    return if (received != 0) received else null;
                },
            }
            for (0..result) |i| {
                const buffer = &buffers[received + i];
                buffer.size = messages[i].len;
                buffer.source = portableAddress(&addresses[i]);
                bytes += buffer.size;
            }
            received += result;
            if (result < count or bytes >= max_bytes) break;
        }
        return received;
    }

    fn nativeAddress(out: *linux.sockaddr.in6, dual_stack: bool, address: io.SocketAddress) ?u32 {
        if (address.family == 4 and !dual_stack) {
            const v4: *linux.sockaddr.in = @ptrCast(out);
            v4.* = .{ .port = std.mem.nativeToBig(u16, address.port), .addr = @bitCast(address.address[0..4].*) };
            return @sizeOf(linux.sockaddr.in);
        }
        if (address.family != 4 and address.family != 6) return null;
        out.* = .{ .port = std.mem.nativeToBig(u16, address.port), .flowinfo = 0, .addr = address.address, .scope_id = address.scope_id };
        if (address.family == 4) out.addr = mapped_prefix ++ address.address[0..4].*;
        return @sizeOf(linux.sockaddr.in6);
    }

    fn portableAddress(address: *const linux.sockaddr.in6) io.SocketAddress {
        var result = std.mem.zeroes(io.SocketAddress);
        if (address.family == linux.AF.INET) {
            const v4: *const linux.sockaddr.in = @ptrCast(address);
            result.family = 4;
            result.port = std.mem.bigToNative(u16, v4.port);
            result.address[0..4].* = @bitCast(v4.addr);
        } else if (std.mem.eql(u8, address.addr[0..12], &mapped_prefix)) {
            result.family = 4;
            result.port = std.mem.bigToNative(u16, address.port);
            result.address[0..4].* = address.addr[12..16].*;
        } else {
            result.family = 6;
            result.port = std.mem.bigToNative(u16, address.port);
            result.address = address.addr;
            result.scope_id = address.scope_id;
        }
        return result;
    }
};

pub const SocketWrapper = struct {
    socket: io_c.pp_socket,
    remote_endpoint: ?io.SocketEndpoint = null,
    closes_on_empty_read: bool = false,
    is_closed: bool = false,
    allocator: std.mem.Allocator,

    /// Creates a connected socket (resolving hostnames in C), or one unconnected UDP socket for the requested families.
    /// A null endpoint selects unconnected UDP.
    /// Ownership transfers on successful looper_v2 attachment.
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

    pub fn isUnconnected(self: *const SocketWrapper) bool {
        return self.remote_endpoint == null;
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
    ) error{OutOfMemory}!?io_c.pp_socket {
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
            socketProto(endpoint),
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

    fn setEventMask(self: *const SocketWrapper, readable: bool, writable: bool) Error!void {
        if (!io_c.pp_socket_set_event_mask(self.socket, readable, writable)) return error.LibcFailure;
    }

    fn resetEvents(self: *const SocketWrapper) Error!void {
        if (!io_c.pp_socket_reset_events(self.socket)) return error.LibcFailure;
    }

    fn read(self: *const SocketWrapper, buf: []u8) Error!?usize {
        if (self.isUnconnected()) return error.InvalidSocketMode;
        const read_count = io_c.pp_socket_read(self.socket, buf.ptr, buf.len, null);
        return mapReadResult(.link, read_count, self.closes_on_empty_read);
    }

    fn write(self: *const SocketWrapper, data: []const u8, offset: usize) Error!usize {
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

    pub fn receiveFrom(self: *SocketWrapper, buf: []u8, address: *io.SocketAddress) Error!usize {
        if (!self.isUnconnected()) return error.InvalidSocketMode;
        const count = io_c.pp_socket_read(self.socket, buf.ptr, buf.len, address);
        if (count == io_c.PPIOErrorWouldBlock) return error.WouldBlock;
        if (count < 0) return datagramError();
        return @intCast(count);
    }

    pub fn sendTo(self: *const SocketWrapper, data: []const u8, address: io.SocketAddress) Error!usize {
        if (!self.isUnconnected()) return error.InvalidSocketMode;
        if (address.family != 4 and address.family != 6) return error.InvalidAddressFamily;
        return mapWriteResult(.link, io_c.pp_socket_write(self.socket, data.ptr, data.len, &address), false) catch |err| {
            return if (err == error.LibcFailure) datagramError() else err;
        };
    }

    fn datagramError() Error {
        // Truncation and per-destination errors (including asynchronous ICMP)
        // do not invalidate a shared UDP socket or its other peers.
        return switch (io_c.pp_socket_last_error_binding()) {
            @intFromEnum(std.c.E.MSGSIZE),
            @intFromEnum(std.c.E.NETUNREACH),
            @intFromEnum(std.c.E.HOSTUNREACH),
            @intFromEnum(std.c.E.CONNREFUSED),
            => error.DatagramDropped,
            else => error.LibcFailure,
        };
    }

    pub fn localAddress(self: *const SocketWrapper) !io.SocketAddress {
        var address: io.SocketAddress = undefined;
        if (!io_c.pp_socket_get_address(self.socket, &address)) return error.LibcFailure;
        return address;
    }

    pub fn remoteAddress(self: *const SocketWrapper) ?io.SocketAddress {
        const endpoint = self.remote_endpoint orelse return null;
        return endpoint.address;
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
    test_descriptor: if (builtin.is_test) ?POSIXDescriptor else void = if (builtin.is_test) null else {},

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

    fn free(self: *TunWrapper) void {
        if (self.is_closed) return;
        self.is_closed = true;
        if (builtin.is_test) if (self.test_descriptor) |descriptor| {
            descriptor.cleanup();
            return;
        };
        io_c.pp_tun_free(self.tun);
    }

    // FIXME: ###, Drop after v2
    pub fn nativeIO(self: *TunWrapper) POSIXInterface {
        return .{ .tun = self };
    }

    fn setEventMask(_: *TunWrapper, _: bool, _: bool) Error!void {}

    fn resetEvents(_: *TunWrapper) Error!void {}

    fn read(self: *const TunWrapper, buf: []u8) Error!?usize {
        if (builtin.is_test) if (self.test_descriptor) |descriptor| return descriptor.io.read(buf);
        const read_count = io_c.pp_tun_read(self.tun, buf.ptr, buf.len);
        return mapReadResult(.tun, read_count, false);
    }

    fn write(self: *const TunWrapper, data: []const u8, offset: usize) Error!usize {
        if (offset > data.len) return error.InvalidOffset;
        if (builtin.is_test) if (self.test_descriptor) |descriptor| return descriptor.io.write(data, offset);
        const written = io_c.pp_tun_write(self.tun, data.ptr + offset, data.len - offset);
        return mapWriteResult(.tun, written, true);
    }

    fn cleanup(self: *TunWrapper) void {
        self.free();
    }

    fn lastErrorCode(_: TunWrapper) c_int {
        return io_c.pp_io_last_error_binding();
    }

    // FIXME: ###, Drop after v2
    pub fn muxDescriptor(self: TunWrapper) ?io_c.pp_fd {
        if (builtin.is_test) if (self.test_descriptor) |descriptor| return descriptor.fd;
        const fd = io_c.pp_tun_get_watch_fd(self.tun);
        return if (io_c.pp_fd_is_valid(fd)) fd else null;
    }

    pub fn name(self: TunWrapper) ?[]const u8 {
        const tun = self.tun orelse return null;
        const c_name = io_c.pp_tun_name(tun) orelse return null;
        return std.mem.span(c_name);
    }

    pub fn tunDescriptor(self: *TunWrapper) Error!TunDescriptor {
        const fd = self.muxDescriptor() orelse return error.LibcFailure;
        if (io_c.pp_fd_set_nonblocking(fd, null) != 0) return error.LibcFailure;
        return .{
            .fd = fd,
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
