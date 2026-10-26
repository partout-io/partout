// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/exports.zig");
const io = @import("io.zig");

/// Owned packet I/O with borrowed receive callbacks. Lifecycle and submissions
/// are owner-serialized. Removing a receiver drains delivery before returning.
/// POSIX uses one readiness-driven reader per descriptor; Windows uses native
/// callbacks. No worker retains a consumer buffer after its callback returns.
pub const CallbackIO = struct {
    pub const OnReceive = ?*const fn (?*anyopaque, [*c]const u8, usize, [*c]const io.SocketAddress, i32) callconv(.c) bool;
    pub const WriteResult = enum { ok, again, dropped, failed };

    allocator: std.mem.Allocator,
    descriptor: io.DescriptorPair,
    state: if (builtin.os.tag == .windows) void else struct {
        lock: core.Mutex = .{},
        waiter: io.Waiter,
        thread: ?std.Thread = null,
        callback: OnReceive = null,
        context: ?*anyopaque = null,
        stopping: bool = false,
        writes_stopped: bool = false,
    },

    /// Takes descriptor ownership on entry, including on allocation failure.
    pub fn create(allocator: std.mem.Allocator, descriptor: io.DescriptorPair) std.mem.Allocator.Error!*CallbackIO {
        errdefer cleanupDescriptor(descriptor);
        const self = try allocator.create(CallbackIO);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .descriptor = descriptor,
            .state = if (builtin.os.tag == .windows) {} else .{
                .waiter = io.Waiter.init() orelse return error.OutOfMemory,
            },
        };
        return self;
    }

    pub fn cleanup(self: *CallbackIO) void {
        self.stopWrites();
        self.setOnReceive(null, null) catch unreachable;
        if (builtin.os.tag != .windows) {
            self.state.waiter.deinit();
            self.state.lock.deinit();
        }
        cleanupDescriptor(self.descriptor);
        self.allocator.destroy(self);
    }

    pub fn setOnReceive(self: *CallbackIO, callback: OnReceive, context: ?*anyopaque) error{ReceiveSetupFailed}!void {
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

    pub fn stopWrites(self: *CallbackIO) void {
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
    pub fn write(self: *CallbackIO, bytes: []const u8, destination: ?io.SocketAddress) WriteResult {
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

    fn receive(self: *CallbackIO) void {
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
            var address = std.mem.zeroes(io.SocketAddress);
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

    fn reportFailure(self: *CallbackIO) void {
        self.state.lock.lock();
        const stopping = self.state.stopping;
        self.state.lock.unlock();
        if (!stopping) _ = self.state.callback.?(self.state.context, null, 0, null, -1);
    }

    fn cleanupDescriptor(descriptor: io.DescriptorPair) void {
        switch (descriptor) {
            inline else => |value| value.cleanup(),
        }
    }
};
