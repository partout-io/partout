// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Shared packets, buffers, reachability, sides, and errors for socket and TUN I/O.
//! Platform-specific descriptors, options, and wrappers belong to the backends
//! selected by `io.zig`. This module does not import either backend.
//! CallbackIO receives its descriptor type from that platform selection.

const std = @import("std");
const builtin = @import("builtin");

const io_mod = @This();
const core = @import("../core/exports.zig");
const ffi = @import("../c/exports.zig");

const api = core.api;
const io_c = ffi.io;

/// Single binary data packet.
pub const Packet = []const u8;
/// Slice of packets.
pub const Packets = []const Packet;

/// Whether to continue reading or pause until the consumer resumes reads.
pub const ReadAction = enum {
    keep,
    pause,
};

/// Deferred readiness, system, side I/O, or consumer callback failure.
pub const Failure = union(enum) {
    wait: c_int,
    system: Error,
    io: struct {
        side: Side,
        cause: Error,
        code: ?c_int,
    },
    user: anyerror,
};

/// Infallible callback for delayed execution. The owner handles failures.
pub const TimedTask = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque) void,

    pub fn call(self: TimedTask) void {
        self.callback(self.context);
    }
};

/// Identity of one replaceable delayed task. The scheduler does not retain
/// this value's address; callers may store it inline with their state.
pub const Timer = struct {
    id: ?u64 = null,
};

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

pub fn socketProto(endpoint: api.ExtendedEndpoint) io_c.pp_socket_proto {
    return switch (endpoint.plainSocketType()) {
        .udp => io_c.PPSocketProtoUDP,
        .tcp => io_c.PPSocketProtoTCP,
    };
}

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

/// Owned packet I/O with borrowed receive callbacks. Lifecycle and submissions
/// are owner-serialized. Removing a receiver drains delivery before returning.
/// POSIX uses one readiness-driven reader per descriptor; Windows uses native
/// callbacks. No worker retains a consumer buffer after its callback returns.
pub fn CallbackIO(comptime Descriptors: type) type {
    return struct {
        const Self = @This();
        pub const OnReceive = ?*const fn (?*anyopaque, [*c]const u8, usize, [*c]const SocketAddress, i32) callconv(.c) bool;
        pub const WriteResult = enum { ok, again, dropped, failed };

        allocator: std.mem.Allocator,
        descriptor: Descriptors,
        state: if (builtin.os.tag == .windows) void else struct {
            lock: core.Mutex = .{},
            waiter: Waiter,
            thread: ?std.Thread = null,
            callback: OnReceive = null,
            context: ?*anyopaque = null,
            stopping: bool = false,
            writes_stopped: bool = false,
        },

        /// Takes descriptor ownership on entry, including on allocation failure.
        pub fn create(allocator: std.mem.Allocator, descriptor: Descriptors) std.mem.Allocator.Error!*Self {
            errdefer cleanupDescriptor(descriptor);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .descriptor = descriptor,
                .state = if (builtin.os.tag == .windows) {} else .{
                    .waiter = Waiter.init() orelse return error.OutOfMemory,
                },
            };
            return self;
        }

        pub fn cleanup(self: *Self) void {
            self.stopWrites();
            self.setOnReceive(null, null) catch unreachable;
            if (builtin.os.tag != .windows) {
                self.state.waiter.deinit();
                self.state.lock.deinit();
            }
            cleanupDescriptor(self.descriptor);
            self.allocator.destroy(self);
        }

        pub fn setOnReceive(self: *Self, callback: OnReceive, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
            if (builtin.os.tag == .windows) {
                switch (self.descriptor) {
                    inline else => |descriptor| try descriptor.setOnReceive(callback, context),
                }
                return;
            }
            if (callback == null) {
                self.state.lock.lock();
                self.state.stopping = true;
                self.state.waiter.wake();
                self.state.lock.unlock();
                if (self.state.thread) |thread| thread.join();
                self.state.thread = null;
                self.state.callback = null;
                self.state.context = null;
                return;
            }
            if (self.state.thread != null) return error.ReceiveSetupFailed;
            self.state.callback = callback;
            self.state.context = context;
            self.state.stopping = false;
            self.state.thread = std.Thread.spawn(.{}, receive, .{self}) catch {
                self.state.callback = null;
                self.state.context = null;
                return error.ReceiveSetupFailed;
            };
        }

        pub fn stopWrites(self: *Self) void {
            if (builtin.os.tag == .windows) {
                switch (self.descriptor) {
                    inline else => |descriptor| descriptor.stopWrites(),
                }
                return;
            }
            self.state.lock.lock();
            self.state.writes_stopped = true;
            self.state.lock.unlock();
        }

        /// Success releases the borrowed bytes; it does not promise transmission.
        pub fn write(self: *Self, bytes: []const u8, destination: ?SocketAddress) WriteResult {
            if (builtin.os.tag == .windows) {
                const result = switch (self.descriptor) {
                    .link => |descriptor| descriptor.write(bytes, destination),
                    .tun => |descriptor| descriptor.write(bytes),
                };
                return if (result == 0) .ok else .failed;
            }
            self.state.lock.lock();
            defer self.state.lock.unlock();
            if (self.state.writes_stopped) return .failed;
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

        fn receive(self: *Self) void {
            const descriptor = switch (self.descriptor) {
                inline else => |descriptor| descriptor,
            };
            var buffer: [65535]u8 = undefined;
            while (true) {
                self.state.lock.lock();
                if (self.state.stopping) {
                    self.state.lock.unlock();
                    return;
                }
                var address = std.mem.zeroes(SocketAddress);
                const size = descriptor.io.readPacket(&buffer, &address) catch |err| {
                    if (err == error.DatagramDropped) {
                        self.state.lock.unlock();
                        continue;
                    }
                    if (err == error.WouldBlock) {
                        _ = descriptor.io.waitForReadiness(false, &self.state.waiter, &self.state.lock) catch {
                            self.state.lock.unlock();
                            self.reportFailure();
                            return;
                        };
                        self.state.lock.unlock();
                        continue;
                    }
                    self.state.lock.unlock();
                    self.reportFailure();
                    return;
                } orelse {
                    self.state.lock.unlock();
                    self.reportFailure();
                    return;
                };
                if (self.descriptor == .link and descriptor.io == .socket and !descriptor.io.isUnconnected())
                    address = descriptor.io.socket.remoteAddress() orelse address;
                self.state.lock.unlock();
                if (!self.state.callback.?(self.state.context, &buffer, size, if (self.descriptor == .link) &address else null, 0)) return;
            }
        }

        fn reportFailure(self: *Self) void {
            self.state.lock.lock();
            const stopping = self.state.stopping;
            self.state.lock.unlock();
            if (!stopping) _ = self.state.callback.?(self.state.context, null, 0, null, -1);
        }

        fn cleanupDescriptor(descriptor: Descriptors) void {
            switch (descriptor) {
                inline else => |value| value.cleanup(),
            }
        }
    };
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
