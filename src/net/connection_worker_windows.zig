// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

//! Windows executor for the shared connection worker's link preparation.
//! This adapter owns no Zig thread and adds no completion or packet queue.
//! The enclosing native runtime owns the borrowed command loop through destroy.
const std = @import("std");
const ffi = @import("../c/exports.zig");
const c = ffi.io;

pub fn Executor(comptime Context: type, comptime Message: type, comptime execute: anytype) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        context: *Context,
        callbacks: c.partout_winrt_callbacks,

        const Task = struct {
            owner: *Self,
            message: Message,

            fn run(raw: ?*anyopaque) callconv(.c) void {
                const self: *Task = @ptrCast(@alignCast(raw.?));
                const owner = self.owner;
                defer owner.allocator.destroy(self);
                execute(owner.context, void, self.message) catch unreachable;
            }
        };

        pub fn create(allocator: std.mem.Allocator, context: *Context) error{OutOfMemory}!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const callbacks = context.factory.winrt orelse return error.OutOfMemory;
            self.* = .{ .allocator = allocator, .context = context, .callbacks = callbacks };
            return self;
        }

        pub fn schedule(self: *Self, message: Message) error{OutOfMemory}!void {
            const task = try self.allocator.create(Task);
            errdefer self.allocator.destroy(task);
            task.* = .{ .owner = self, .message = message };
            if (!self.callbacks.submit.?(self.callbacks.context, Task.run, task)) return error.OutOfMemory;
        }

        pub fn destroy(self: *Self) void {
            // Drain accepted preparation before freeing its Zig context. The
            // native loop is borrowed and remains owned by VpnChannelRuntime.
            self.callbacks.drain.?(self.callbacks.context);
            self.allocator.destroy(self);
        }
    };
}
