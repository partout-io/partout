// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
const std = @import("std");
const source = @import("source");
const c = source.ffi.io;
const core = source.core;

/// Fake serial executor for core tests; native I/O belongs to C++ tests.
pub const NativeRuntime = struct {
    actor: ?*Actor = null,
    const Task = struct { run: ?*const fn (?*anyopaque) callconv(.c) void = null, context: ?*anyopaque = null };
    const Actor = core.actor.Actor(u8, null, Task, error{}, execute);
    var context: u8 = 0;
    fn execute(_: *u8, comptime Result: type, task: Task) error{}!Result {
        if (task.run) |run| run(task.context);
    }
    pub fn init() !NativeRuntime {
        if (!source.net.uses_winrt) return .{};
        const actor = try Actor.create(std.testing.allocator, &context);
        source.mock.winrt_callbacks = .{ .context = actor, .connect = connect, .submit = submit, .drain = drain };
        return .{ .actor = actor };
    }
    pub fn deinit(self: NativeRuntime) void {
        const actor = self.actor orelse return;
        actor.destroy();
        source.mock.winrt_callbacks = .{};
    }
    fn submit(raw: ?*anyopaque, run: ?*const fn (?*anyopaque) callconv(.c) void, task: ?*anyopaque) callconv(.c) bool {
        const actor: *Actor = @ptrCast(@alignCast(raw orelse return false));
        actor.schedule(.{ .run = run, .context = task }) catch return false;
        return true;
    }
    fn drain(raw: ?*anyopaque) callconv(.c) void {
        const actor: *Actor = @ptrCast(@alignCast(raw orelse return));
        actor.perform(void, .{}) catch unreachable;
    }
    fn connect(_: ?*anyopaque, _: [*c]const u8, _: c.partout_socket_proto, _: u16, options: [*c]const c.partout_socket_open_options) callconv(.c) ?*c.partout_transport {
        if (options.*.configure) |configure| {
            if (!configure(options.*.configure_ctx, 1, options.*.reachability)) return null;
        }
        return &transport;
    }
    fn release(_: ?*anyopaque) callconv(.c) void {}
    fn subscribe(_: ?*anyopaque, _: c.partout_transport_receive, _: ?*anyopaque) callconv(.c) bool {
        return true;
    }
    fn resumeReads(_: ?*anyopaque) callconv(.c) bool {
        return true;
    }
    fn stop(_: ?*anyopaque) callconv(.c) void {}
    fn write(_: ?*anyopaque, _: [*c]const u8, _: usize, _: [*c]const c.partout_socket_address) callconv(.c) i32 {
        return 0;
    }
    fn address(_: ?*anyopaque, out: [*c]c.partout_socket_address) callconv(.c) bool {
        const value = source.net_io.testing.socketAddress(.{ .address = "127.0.0.1", .proto = .init(.udp, 12345) }) catch return false;
        out.* = value;
        return true;
    }
    var transport: c.partout_transport = .{ .release = release, .subscribe = subscribe, .@"resume" = resumeReads, .stop = stop, .write = write, .local_address = address };
};
