// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");
const Looper = source.net_looper_posix_st.PosixLooper;
const helpers = source.net_looper_helpers;
const io = source.net_io;
const allocator = std.testing.allocator;

const Probe = struct {
    looper: *Looper = undefined,
    finishes: usize = 0,
    tasks: usize = 0,
    timer: helpers.Timer = .{},
    fn finish(raw: ?*anyopaque, failure: ?helpers.Failure) void {
        const self: *Probe = @ptrCast(@alignCast(raw.?));
        std.debug.assert(failure == null);
        self.finishes += 1;
    }
    fn task(raw: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw.?));
        self.tasks += 1;
        // A zero-delay replacement must wait for another caller-driven iteration.
        self.looper.scheduleReplacing(&self.timer, 0, .{ .context = self, .callback = task }) catch unreachable;
    }
};

test "ST looper lifecycle and timers are caller driven" {
    var probe = Probe{};
    const loop = try Looper.create(allocator, .{ .on_finish = .{ .context = &probe, .callback = Probe.finish } });
    defer loop.destroy();
    probe.looper = loop;
    try std.testing.expect(!loop.loopOnce(0));
    try loop.stop();
    try loop.start();
    try std.testing.expectError(error.AlreadyStarted, loop.start());
    try loop.scheduleReplacing(&probe.timer, 1000, .{ .context = &probe, .callback = Probe.task });
    try loop.scheduleReplacing(&probe.timer, 0, .{ .context = &probe, .callback = Probe.task });
    try std.testing.expectEqual(0, probe.tasks);
    try std.testing.expect(loop.loopOnce(0));
    try std.testing.expectEqual(1, probe.tasks);
    try std.testing.expect(loop.loopOnce(0));
    try std.testing.expectEqual(2, probe.tasks);
    loop.cancelTimer(&probe.timer);
    try std.testing.expect(loop.loopOnce(0));
    try std.testing.expectEqual(2, probe.tasks);
    try loop.scheduleReplacing(&probe.timer, 2, .{ .context = &probe, .callback = Probe.task });
    try std.testing.expect(loop.loopOnce(null));
    try std.testing.expectEqual(3, probe.tasks);
    try loop.stop();
    try loop.stop();
    try std.testing.expectEqual(1, probe.finishes);
    try std.testing.expect(!loop.loopOnce(0));
    try std.testing.expectError(error.LooperUnavailable, loop.scheduleReplacing(&probe.timer, 0, .{ .callback = Probe.task }));
}

const Mock = struct {
    fd: std.c.fd_t,
    loop: *Looper,
    storage: [16]u8 = undefined,
    buffers: [1]helpers.ReadBuffer = undefined,
    reads: usize = 0,
    has_read: bool = false,
    releases: usize = 0,
    cleanups: usize = 0,
    completions: usize = 0,
    result: helpers.IOResult = .{},
    backpressure: bool = false,
    block: bool = false,
    fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn reset(_: *anyopaque) io.Error!void {}
    fn read(raw: *anyopaque, data: []u8) io.Error!?usize {
        const self: *Mock = @ptrCast(@alignCast(raw));
        if (self.has_read) return error.WouldBlock;
        self.has_read = true;
        const n = std.c.read(self.fd, data.ptr, data.len);
        if (n < 0) return error.LibcFailure;
        return @intCast(n);
    }
    fn write(raw: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
        const self: *Mock = @ptrCast(@alignCast(raw));
        if (self.block) return error.WouldBlock;
        if (self.backpressure) {
            self.backpressure = false;
            return error.Backpressure;
        }
        return data.len - offset;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *Mock = @ptrCast(@alignCast(raw));
        self.cleanups += 1;
    }
    fn code(_: *anyopaque) c_int {
        return 0;
    }
    fn acquire(raw: ?*anyopaque) []helpers.ReadBuffer {
        const self: *Mock = @ptrCast(@alignCast(raw.?));
        return &self.buffers;
    }
    fn release(raw: ?*anyopaque, _: []helpers.ReadBuffer, _: helpers.IOResult) void {
        const self: *Mock = @ptrCast(@alignCast(raw.?));
        self.releases += 1;
    }
    fn onRead(raw: ?*anyopaque, packets: helpers.Packets, _: ?[]const io.SocketAddress) anyerror!helpers.ReadAction {
        const self: *Mock = @ptrCast(@alignCast(raw.?));
        self.reads += 1;
        try std.testing.expectEqualStrings("x", packets[0]);
        try std.testing.expectError(error.ReentrantCall, self.loop.detach(.tun));
        try std.testing.expectError(error.ReentrantCall, self.loop.stop());
        return .pause;
    }
    fn complete(raw: ?*anyopaque, result: helpers.IOResult) void {
        const self: *Mock = @ptrCast(@alignCast(raw.?));
        self.completions += 1;
        self.result = result;
    }
    fn descriptor(self: *Mock) source.net_io_posix.POSIXDescriptor {
        const vtable = source.net_io_posix.POSIXInterface.Mock.VTable{
            .set_event_mask = mask,
            .reset_events = reset,
            .read = read,
            .write = write,
            .cleanup = cleanup,
            .last_error_code = code,
        };
        return .{ .fd = self.fd, .io = .{ .mock = .{ .ptr = self, .vtable = &vtable } } };
    }
};

test "ST looper inline reads writes retries and synchronous detach" {
    var probe = Probe{};
    const loop = try Looper.create(allocator, .{ .on_finish = .{ .context = &probe, .callback = Probe.finish } });
    defer loop.destroy();
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var mock = Mock{ .fd = fds[0], .loop = loop };
    mock.buffers = .{.{ .data = &mock.storage }};
    try loop.start();
    const args = helpers.AttachArguments{
        .pair = .{ .tun = mock.descriptor() },
        .read_buffers = .{ .context = &mock, .acquire = Mock.acquire, .release = Mock.release },
        .on_read = .{ .context = &mock, .callback = Mock.onRead },
    };
    try loop.attach(args);
    try std.testing.expect(loop.isTunAttached());
    try std.testing.expect(!loop.isLinkAttached());
    try std.testing.expectError(error.SideAlreadyAttached, loop.attach(args));
    try std.testing.expectEqual(1, std.c.write(fds[1], "x", 1));
    try std.testing.expectEqual(0, mock.reads);
    try std.testing.expect(loop.loopOnce(0));
    try std.testing.expectEqual(1, mock.reads);
    try std.testing.expectEqual(1, mock.releases);
    try loop.resumeReading(.tun);
    mock.backpressure = true;
    const packets: helpers.Packets = &.{"abc"};
    const completion = helpers.OnWriteComplete{ .context = &mock, .callback = Mock.complete };
    try loop.writeQueued(packets, .tun, null, completion);
    try std.testing.expectEqual(0, mock.completions);
    try std.testing.expect(loop.loopOnce(0));
    try std.testing.expectEqual(0, mock.completions);
    try std.testing.expect(loop.loopOnce(null));
    try std.testing.expectEqual(1, mock.completions);
    try std.testing.expectEqual(1, mock.result.count);
    try loop.writeOutOfBand(packets, .tun, null);
    mock.block = true;
    try loop.writeQueued(packets, .tun, null, completion);
    try std.testing.expect(loop.loopOnce(0));
    try loop.detach(.tun);
    try std.testing.expectEqual(2, mock.completions);
    try std.testing.expectEqual(error.Cancelled, mock.result.failure.?);
    try std.testing.expectEqual(1, mock.cleanups);
    try std.testing.expect(!loop.isTunAttached());
    try loop.stop();
}
