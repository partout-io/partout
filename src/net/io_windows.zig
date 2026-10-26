// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const build_options = @import("build_options");
const ffi = @import("../c/exports.zig");

const core = @import("../core/exports.zig");
const io = @import("io_common.zig");
const api = core.api;
const io_c = ffi.io;
const util = core.util;

pub const OnReceive = ?*const fn (?*anyopaque, [*c]const u8, usize, [*c]const io.SocketAddress, i32) callconv(.c) bool;
pub const LinkDescriptor = *SocketWrapper;
pub const TunDescriptor = *TunWrapper;

// Native registration publishes these fields; native removal drains their readers.
const Receiver = struct {
    callback: OnReceive = null,
    context: ?*anyopaque = null,

    fn Handle(comptime tag: io.Side) type {
        return if (tag == .link) io_c.winrt_socket else io_c.winrt_tun;
    }

    fn set(self: *Receiver, comptime tag: io.Side, handle: Handle(tag), callback: OnReceive, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
        if (callback != null and self.callback != null) return error.ReceiveSetupFailed;
        if (callback == null) {
            if (!setNative(tag, handle, null)) @panic("Failed to clear WinRT receive callback");
            self.* = .{};
            return;
        }
        self.* = .{ .callback = callback, .context = context };
        errdefer self.* = .{};
        if (!setNative(tag, handle, self)) return error.ReceiveSetupFailed;
    }

    fn setNative(comptime tag: io.Side, handle: Handle(tag), receiver: ?*Receiver) bool {
        return switch (tag) {
            .link => io_c.winrt_socket_set_on_receive(handle, if (receiver == null) null else onSocketReceive, receiver),
            .tun => io_c.winrt_tun_set_on_receive(handle, if (receiver == null) null else onTunReceive, receiver),
        };
    }

    fn onSocketReceive(raw: ?*anyopaque, bytes: [*c]const u8, length: usize, source: [*c]const io_c.winrt_socket_address, code: i32) callconv(.c) bool {
        const self: *Receiver = @ptrCast(@alignCast(raw.?));
        const callback = self.callback orelse return false;
        const address: ?io.SocketAddress = if (source == null) null else fromNativeAddress(source[0]);
        return callback(self.context, bytes, length, if (address) |*value| value else null, code);
    }

    fn onTunReceive(raw: ?*anyopaque, bytes: [*c]const u8, length: usize) callconv(.c) bool {
        const self: *Receiver = @ptrCast(@alignCast(raw.?));
        const callback = self.callback orelse return false;
        return callback(self.context, bytes, length, null, 0);
    }
};

fn fromNativeAddress(address: io_c.winrt_socket_address) io.SocketAddress {
    return .{
        .address = address.address,
        .scope_id = address.scope_id,
        .port = address.port,
        .family = address.family,
    };
}

fn toNativeAddress(address: io.SocketAddress) io_c.winrt_socket_address {
    return .{
        .address = address.address,
        .scope_id = address.scope_id,
        .port = address.port,
        .family = address.family,
    };
}

pub const SocketWrapper = struct {
    allocator: std.mem.Allocator,
    socket: io_c.winrt_socket,
    receiver: Receiver = .{},
    unconnected: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        endpoint: ?api.ExtendedEndpoint,
        options: io.SocketOptions,
    ) std.mem.Allocator.Error!?*SocketWrapper {
        if (!build_options.winrt) @panic("WinRT socket C ABI is not linked");
        const unconnected = endpoint == null;
        if (unconnected and !options.ipv4 and !options.ipv6) return null;
        const peer = endpoint orelse api.ExtendedEndpoint{
            .address = if (options.ipv6) "::" else "0.0.0.0",
            .proto = .init(.udp, options.port),
        };
        var c_address: util.TemporaryCString = .{};
        try c_address.init(allocator, peer.address);
        defer c_address.deinit();

        const socket = io_c.winrt_socket_create(switch (peer.plainSocketType()) {
            .tcp => io_c.WinrtSocketProtoTCP,
            .udp => io_c.WinrtSocketProtoUDP,
        }, unconnected) orelse return null;
        var transferred = false;
        defer if (!transferred) io_c.winrt_socket_free(socket);
        // uintptr_t carries the WinRT wrapper through the same callback ABI as
        // POSIX descriptors. It must never be used as a Winsock SOCKET.
        const reachability = options.reachability orelse io.reachabilityNone();
        if (options.configure) |configure| {
            if (!configure(options.configure_ctx, @intFromPtr(socket), &reachability)) return null;
        }
        // AssociateTransport has completed before either bind or connect.
        if (!io_c.winrt_socket_open(
            socket,
            c_address.ptr(),
            peer.proto.port,
            &.{
                .dual_stack = unconnected and options.ipv4 and options.ipv6,
                .timeout_ms = options.timeout_ms,
            },
        )) return null;
        const self = try allocator.create(SocketWrapper);
        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .unconnected = unconnected,
        };
        transferred = true;
        return self;
    }

    pub fn destroy(self: *SocketWrapper) void {
        if (!build_options.winrt) @panic("WinRT socket C ABI is not linked");
        io_c.winrt_socket_free(self.socket);
        self.allocator.destroy(self);
    }

    pub fn localAddress(self: *const SocketWrapper) !io.SocketAddress {
        if (!build_options.winrt) @panic("WinRT socket C ABI is not linked");
        var address: io_c.winrt_socket_address = undefined;
        if (!io_c.winrt_socket_get_address(self.socket, &address)) return error.LibcFailure;
        return fromNativeAddress(address);
    }

    pub fn cleanup(self: *SocketWrapper) void {
        self.destroy();
    }

    pub fn linkDescriptor(self: *SocketWrapper) LinkDescriptor {
        return self;
    }

    pub fn socketWrapper(self: *SocketWrapper) ?*SocketWrapper {
        return self;
    }

    /// Register once on attach, clear on detach. Clearing drains native delivery
    /// before releasing the borrowed context. The callback consumes borrowed input.
    pub fn setOnReceive(self: *SocketWrapper, callback: OnReceive, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
        if (!build_options.winrt) @panic("WinRT socket C ABI is not linked");
        try self.receiver.set(.link, self.socket, callback, context);
    }

    pub fn resumeReading(self: *SocketWrapper) !void {
        if (!build_options.winrt) @panic("WinRT socket C ABI is not linked");
        if (!io_c.winrt_socket_resume_reading(self.socket)) return error.ReceiveSetupFailed;
    }

    pub fn stopWrites(self: *SocketWrapper) void {
        if (!build_options.winrt) @panic("WinRT socket C ABI is not linked");
        io_c.winrt_socket_stop_writes(self.socket);
    }

    /// Zero means accepted. Immediate failures return HRESULT; async failures
    /// use the receive callback. Unconnected UDP requires a destination.
    pub fn write(self: *SocketWrapper, packet: io.Packet, destination: ?io.SocketAddress) i32 {
        if (!build_options.winrt) @panic("WinRT socket C ABI is not linked");
        const native: ?io_c.winrt_socket_address = if (destination) |address| toNativeAddress(address) else null;
        return io_c.winrt_socket_write(self.socket, packet.ptr, packet.len, if (native) |*address| address else null);
    }
};

pub const TunWrapper = struct {
    allocator: std.mem.Allocator,
    tun: io_c.winrt_tun,
    receiver: Receiver = .{},

    pub fn create(allocator: std.mem.Allocator, tun: io_c.pp_tun) std.mem.Allocator.Error!*TunWrapper {
        if (!build_options.winrt) @panic("WinRT TUN C ABI is not linked");
        const self = try allocator.create(TunWrapper);
        self.* = .{
            .allocator = allocator,
            .tun = @ptrCast(tun),
        };
        return self;
    }

    pub fn destroy(self: *TunWrapper) void {
        io_c.winrt_tun_free(self.tun);
        self.allocator.destroy(self);
    }

    pub fn cleanup(self: *TunWrapper) void {
        self.destroy();
    }

    pub fn tunDescriptor(self: *TunWrapper) !TunDescriptor {
        return self;
    }

    pub fn tunWrapper(self: *TunWrapper) ?*TunWrapper {
        return self;
    }

    pub fn setOnReceive(self: *TunWrapper, callback: OnReceive, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
        if (!build_options.winrt) @panic("WinRT TUN C ABI is not linked");
        try self.receiver.set(.tun, self.tun, callback, context);
    }

    pub fn stopWrites(self: *TunWrapper) void {
        if (!build_options.winrt) @panic("WinRT TUN C ABI is not linked");
        io_c.winrt_tun_stop_writes(self.tun);
    }

    /// Synchronously copies one packet; zero means success, otherwise HRESULT.
    pub fn write(self: *TunWrapper, packet: io.Packet) i32 {
        if (!build_options.winrt) @panic("WinRT TUN C ABI is not linked");
        return io_c.winrt_tun_write(self.tun, packet.ptr, packet.len);
    }
};

/// Native delivery and copied asynchronous writes are owned by WinRT.
pub fn PacketTransport(comptime Descriptors: type) type {
    return struct {
        const Self = @This();
        pub const Descriptor = Descriptors;
        pub const OnReceive = io.PacketReceiveCallback;
        pub const WriteResult = io.PacketWriteResult;

        allocator: std.mem.Allocator,
        descriptor: Descriptors,

        /// Takes descriptor ownership on entry, including allocation failure.
        pub fn create(allocator: std.mem.Allocator, descriptor: Descriptors) std.mem.Allocator.Error!*Self {
            errdefer releaseDescriptor(descriptor);
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .descriptor = descriptor };
            return self;
        }

        pub fn cleanup(self: *Self) void {
            self.stopWrites();
            self.setOnReceive(null, null) catch unreachable;
            releaseDescriptor(self.descriptor);
            self.allocator.destroy(self);
        }

        pub fn setOnReceive(self: *Self, callback: Self.OnReceive, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
            switch (self.descriptor) {
                inline else => |descriptor| try descriptor.setOnReceive(callback, context),
            }
        }

        pub fn stopWrites(self: *Self) void {
            switch (self.descriptor) {
                inline else => |descriptor| descriptor.stopWrites(),
            }
        }

        /// Native acceptance releases the caller's bytes, before transmission.
        pub fn write(self: *Self, bytes: []const u8, destination: ?io.SocketAddress) WriteResult {
            const result = switch (self.descriptor) {
                .link => |descriptor| descriptor.write(bytes, destination),
                .tun => |descriptor| descriptor.write(bytes),
            };
            return if (result == 0) .ok else .failed;
        }

        pub fn releaseDescriptor(descriptor: Descriptors) void {
            switch (descriptor) {
                inline else => |value| value.cleanup(),
            }
        }
    };
}
