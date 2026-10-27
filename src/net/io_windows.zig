// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

//! Windows setup and owned transport capabilities. Native I/O runs on one C++
//! command worker; callbacks enqueue daemon messages or feed passive consumers.
const std = @import("std");
const build_options = @import("build_options");
const ffi = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const io = @import("io_common.zig");
const c = ffi.io;

pub const LinkDescriptor = *SocketWrapper;
pub const TunDescriptor = *TunWrapper;

pub fn threadEnter() error{LibcFailure}!void {
    if (build_options.winrt and !c.winrt_thread_enter()) return error.LibcFailure;
}

pub fn threadExit() void {
    if (build_options.winrt) c.winrt_thread_exit();
}

fn NativeTransport(comptime side: io.Side) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        native: *c.winrt_transport,

        pub fn wrap(allocator: std.mem.Allocator, native: *c.winrt_transport) std.mem.Allocator.Error!*Self {
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .native = native };
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.native.release.?(self.native.context);
            self.allocator.destroy(self);
        }

        pub const cleanup = destroy;

        pub fn localAddress(self: *const Self) !io.SocketAddress {
            var address: io.SocketAddress = undefined;
            if (!self.native.local_address.?(self.native.context, @ptrCast(&address))) return error.LibcFailure;
            return address;
        }

        pub fn setOnReceive(self: *Self, callback: io.PacketReceiveCallback, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
            if (!self.native.subscribe.?(self.native.context, @ptrCast(callback), context)) return error.ReceiveSetupFailed;
        }

        pub fn stopWrites(self: *Self) void {
            self.native.stop.?(self.native.context);
        }

        pub fn resumeReading(self: *Self) !void {
            if (!self.native.@"resume".?(self.native.context)) return error.ReceiveSetupFailed;
        }

        pub fn linkDescriptor(self: *Self) LinkDescriptor {
            return self;
        }

        pub fn tunDescriptor(self: *Self) !TunDescriptor {
            return self;
        }

        pub fn tunWrapper(self: *Self) ?*TunWrapper {
            return if (side == .tun) self else null;
        }

        pub fn write(self: *Self, packet: io.Packet, destination: ?io.SocketAddress) i32 {
            return self.native.write.?(self.native.context, packet.ptr, packet.len, if (destination) |*address| @ptrCast(address) else null);
        }

        // Compatibility with the platform factory. Native setup is one loop
        // operation; Zig never creates or configures a native socket object.
        pub const create = if (side == .link) createLink else createTun;

        fn createLink(allocator: std.mem.Allocator, endpoint: ?core.api.ExtendedEndpoint, options: io.SocketOptions) std.mem.Allocator.Error!?*Self {
            if (!build_options.winrt) return null;
            if (endpoint == null and !options.ipv4 and !options.ipv6) return null;
            const peer = endpoint orelse core.api.ExtendedEndpoint{
                .address = if (options.ipv6) "::" else "0.0.0.0",
                .proto = .init(.udp, options.port),
            };
            var host: core.util.TemporaryCString = .{};
            try host.init(allocator, peer.address);
            defer host.deinit();
            const options_ctx = @constCast(&options);
            const native: *c.winrt_transport = c.winrt_connect(
                host.ptr(),
                peer.proto.port,
                &.{
                    .tcp = peer.plainSocketType() == .tcp,
                    .unconnected = endpoint == null,
                    .dual_stack = endpoint == null and options.ipv4 and options.ipv6,
                    .timeout_ms = options.timeout_ms,
                    .configure = configure,
                    .context = options_ctx,
                },
            ) orelse return null;
            // Release the native transport if allocating its Zig wrapper fails.
            errdefer native.release.?(native.context);
            return try wrap(allocator, native);
        }

        fn createTun(allocator: std.mem.Allocator, tun: c.pp_tun) std.mem.Allocator.Error!*Self {
            return wrap(allocator, @ptrCast(@alignCast(tun)));
        }

        fn configure(raw: ?*anyopaque, token: usize) callconv(.c) bool {
            const options: *io.SocketOptions = @ptrCast(@alignCast(raw.?));
            const callback = options.configure orelse return true;
            const reachability = options.reachability orelse io.reachabilityNone();
            return callback(options.configure_ctx, token, &reachability);
        }
    };
}

pub const SocketWrapper = NativeTransport(.link);
pub const TunWrapper = NativeTransport(.tun);

pub fn CallbackTransport(comptime DescriptorType: type) type {
    return struct {
        const Self = @This();
        pub const Descriptor = DescriptorType;
        pub const OnReceive = io.PacketReceiveCallback;
        pub const WriteResult = io.PacketWriteResult;

        allocator: std.mem.Allocator,
        descriptor: Descriptor,

        pub fn create(allocator: std.mem.Allocator, descriptor: Descriptor) std.mem.Allocator.Error!*Self {
            errdefer releaseDescriptor(descriptor);
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .descriptor = descriptor };
            return self;
        }

        pub fn cleanup(self: *Self) void {
            releaseDescriptor(self.descriptor);
            self.allocator.destroy(self);
        }

        pub fn setOnReceive(self: *Self, callback: Self.OnReceive, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
            switch (self.descriptor) {
                inline else => |value| try value.setOnReceive(callback, context),
            }
        }

        pub fn write(self: *Self, bytes: []const u8, destination: ?io.SocketAddress) WriteResult {
            const result = switch (self.descriptor) {
                inline else => |value| value.write(bytes, destination),
            };
            return if (result == 0) .ok else .failed;
        }

        pub fn releaseDescriptor(descriptor: Descriptor) void {
            switch (descriptor) {
                inline else => |value| value.cleanup(),
            }
        }
    };
}
