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

const WinRT = io_c;

pub const OnReceive = ?*const fn (?*anyopaque, [*c]const u8, usize, [*c]const io.SocketAddress, i32) callconv(.c) bool;
pub const LinkDescriptor = *SocketWrapper;
pub const TunDescriptor = *TunWrapper;

pub const SocketWrapper = struct {
    allocator: std.mem.Allocator,
    socket: WinRT.winrt_socket,
    on_receive: OnReceive = null,
    receive_context: ?*anyopaque = null,
    unconnected: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        endpoint: ?api.ExtendedEndpoint,
        options: io.SocketOptions,
    ) std.mem.Allocator.Error!?*SocketWrapper {
        if (!build_options.winrt) return null;
        if (endpoint == null and !options.ipv4 and !options.ipv6) return null;
        const peer = endpoint orelse api.ExtendedEndpoint{
            .address = if (options.ipv6) "::" else "0.0.0.0",
            .proto = .init(.udp, options.port),
        };
        var c_address: util.TemporaryCString = .{};
        try c_address.init(allocator, peer.address);
        defer c_address.deinit();

        const socket = WinRT.winrt_socket_create(switch (peer.plainSocketType()) {
            .tcp => WinRT.WinrtSocketProtoTCP,
            .udp => WinRT.WinrtSocketProtoUDP,
        }) orelse return null;
        errdefer WinRT.winrt_socket_free(socket);
        // uintptr_t carries the WinRT wrapper through the same callback ABI as
        // POSIX descriptors. It must never be used as a Winsock SOCKET.
        const reachability = options.reachability orelse io.reachabilityNone();
        if (options.configure) |configure| {
            if (!configure(options.configure_ctx, @intFromPtr(socket), &reachability)) {
                WinRT.winrt_socket_free(socket);
                return null;
            }
        }
        // AssociateTransport has completed before either bind or connect.
        if (!WinRT.winrt_socket_open(
            socket,
            c_address.ptr(),
            peer.proto.port,
            &.{
                .unconnected = endpoint == null,
                .dual_stack = endpoint == null and options.ipv4 and options.ipv6,
                .timeout_ms = options.timeout_ms,
            },
        )) {
            WinRT.winrt_socket_free(socket);
            return null;
        }
        const self = try allocator.create(SocketWrapper);
        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .unconnected = endpoint == null,
        };
        return self;
    }

    pub fn destroy(self: *SocketWrapper) void {
        if (build_options.winrt) WinRT.winrt_socket_free(self.socket);
        self.allocator.destroy(self);
    }

    pub fn localAddress(self: *const SocketWrapper) !io.SocketAddress {
        if (!build_options.winrt) return error.LooperUnavailable;
        var address: WinRT.winrt_socket_address = undefined;
        if (!WinRT.winrt_socket_get_address(self.socket, &address)) return error.LibcFailure;
        return .{
            .address = address.address,
            .scope_id = address.scope_id,
            .port = address.port,
            .family = address.family,
        };
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
    /// before releasing the borrowed context. The callback only queues input.
    pub fn setOnReceive(
        self: *SocketWrapper,
        callback: OnReceive,
        context: ?*anyopaque,
    ) io.SubmissionError!void {
        if (!build_options.winrt) return error.LooperUnavailable;
        if (callback == null) {
            if (!WinRT.winrt_socket_set_on_receive(self.socket, null, null)) return error.LooperUnavailable;
        } else if (self.on_receive != null) return error.LooperUnavailable;
        self.on_receive = callback;
        self.receive_context = context;
        if (callback != null and !WinRT.winrt_socket_set_on_receive(self.socket, onNativeReceive, self)) {
            self.on_receive = null;
            self.receive_context = null;
            return error.LooperUnavailable;
        }
    }

    fn onNativeReceive(
        context: ?*anyopaque,
        bytes: [*c]const u8,
        length: usize,
        source: [*c]const WinRT.winrt_socket_address,
        code: i32,
    ) callconv(.c) bool {
        const self: *SocketWrapper = @ptrCast(@alignCast(context.?));
        const callback = self.on_receive orelse return false;
        var address: io.SocketAddress = undefined;
        if (source != null) address = .{
            .address = source[0].address,
            .scope_id = source[0].scope_id,
            .port = source[0].port,
            .family = source[0].family,
        };
        return callback(self.receive_context, bytes, length, if (source == null) null else &address, code);
    }

    pub fn resumeReading(self: *SocketWrapper) io.SubmissionError!void {
        if (!build_options.winrt or !WinRT.winrt_socket_resume_reading(self.socket))
            return error.LooperUnavailable;
    }

    pub fn stopWrites(self: *SocketWrapper) void {
        if (build_options.winrt) WinRT.winrt_socket_stop_writes(self.socket);
    }

    /// Completes a whole packet write; UDP requires a destination when unconnected.
    /// Native failures are returned by value for the looper's on_failure callback.
    pub fn write(
        self: *SocketWrapper,
        packet: io.Packet,
        destination: ?io.SocketAddress,
    ) io.SubmissionError!?io.Failure {
        if (!build_options.winrt) return error.LooperUnavailable;
        const native: ?WinRT.winrt_socket_address = if (destination) |address| .{
            .address = address.address,
            .scope_id = address.scope_id,
            .port = address.port,
            .family = address.family,
        } else null;
        const code = WinRT.winrt_socket_write(self.socket, packet.ptr, packet.len, if (native) |*address| address else null);
        return if (code == 0) null else .{ .io = .{
            .side = .link,
            .cause = error.LibcFailure,
            .code = code,
        } };
    }
};

pub const TunWrapper = struct {
    allocator: std.mem.Allocator,
    tun: io_c.pp_tun,
    on_receive: OnReceive = null,
    receive_context: ?*anyopaque = null,

    pub fn create(allocator: std.mem.Allocator, tun: io_c.pp_tun) std.mem.Allocator.Error!*TunWrapper {
        const self = try allocator.create(TunWrapper);
        self.* = .{
            .allocator = allocator,
            .tun = tun,
        };
        return self;
    }

    pub fn destroy(self: *TunWrapper) void {
        io_c.pp_tun_free(self.tun);
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

    pub fn setOnReceive(self: *TunWrapper, callback: OnReceive, context: ?*anyopaque) io.SubmissionError!void {
        if (!build_options.winrt) return error.LooperUnavailable;
        const native: WinRT.winrt_tun = @ptrCast(self.tun);
        if (callback == null) {
            if (!WinRT.winrt_tun_set_on_receive(native, null, null)) return error.LooperUnavailable;
        } else if (self.on_receive != null) return error.LooperUnavailable;
        self.on_receive = callback;
        self.receive_context = context;
        if (callback != null and !WinRT.winrt_tun_set_on_receive(native, onNativeReceive, self)) {
            self.on_receive = null;
            self.receive_context = null;
            return error.LooperUnavailable;
        }
    }

    fn onNativeReceive(context: ?*anyopaque, bytes: [*c]const u8, length: usize) callconv(.c) bool {
        const self: *TunWrapper = @ptrCast(@alignCast(context.?));
        return if (self.on_receive) |callback| callback(self.receive_context, bytes, length, null, 0) else false;
    }

    pub fn stopWrites(self: *TunWrapper) void {
        if (build_options.winrt) WinRT.winrt_tun_stop_writes(@ptrCast(self.tun));
    }

    pub fn write(self: *TunWrapper, packet: io.Packet) io.SubmissionError!?io.Failure {
        if (!build_options.winrt) return error.LooperUnavailable;
        const code = WinRT.winrt_tun_write(@ptrCast(self.tun), packet.ptr, packet.len);
        return if (code == 0) null else .{ .io = .{ .side = .tun, .cause = error.LibcFailure, .code = code } };
    }
};
