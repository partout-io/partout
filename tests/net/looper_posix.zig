// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");
const Looper = source.net_looper_posix.PosixLooper;
const helpers = source.net_looper.testing_helpers;
const io = source.net_io;
const allocator = std.testing.allocator;

const test_helpers = @import("looper_test_helpers.zig");
const WakeMux = test_helpers.Mux;

const Probe = struct {
    looper: *Looper = undefined,
    tasks: usize = 0,
    timer: helpers.Timer = .{},
    fn task(raw: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw.?));
        self.tasks += 1;
        // A zero-delay replacement must wait for another caller-driven iteration.
        self.looper.scheduleTimer(&self.timer, 0, .{ .context = self, .callback = task }) catch unreachable;
    }
};

test "looper lifecycle and timers are caller driven" {
    var probe = Probe{};
    const wake = try WakeMux.init();
    defer wake.deinit();
    const loop = try Looper.create(allocator, .{
        .mux = wake.handle,
    });
    defer loop.destroy();
    probe.looper = loop;
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try loop.scheduleTimer(&probe.timer, 1000, .{ .context = &probe, .callback = Probe.task });
    try loop.scheduleTimer(&probe.timer, 0, .{ .context = &probe, .callback = Probe.task });
    try std.testing.expectEqual(0, probe.tasks);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(1, probe.tasks);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(2, probe.tasks);
    loop.cancelTimer(&probe.timer);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(2, probe.tasks);
    try loop.scheduleTimer(&probe.timer, 2, .{ .context = &probe, .callback = Probe.task });
    try std.testing.expect(try test_helpers.poll(&loop, null));
    try std.testing.expectEqual(3, probe.tasks);
    try loop.stop();
    try loop.stop();
    try std.testing.expect(!try test_helpers.poll(&loop, 0));
    try std.testing.expectError(error.LooperUnavailable, loop.scheduleTimer(&probe.timer, 0, .{ .callback = Probe.task }));
}

const Mock = struct {
    fd: std.c.fd_t,
    loop: *Looper,
    reads: usize = 0,
    has_read: bool = false,
    cleanups: usize = 0,
    successful_writes: usize = 0,
    backpressure: bool = false,
    block: bool = false,
    writes: usize = 0,
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
        self.writes += 1;
        if (self.block) return error.WouldBlock;
        if (self.backpressure) {
            self.backpressure = false;
            return error.Backpressure;
        }
        self.successful_writes += 1;
        return data.len - offset;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *Mock = @ptrCast(@alignCast(raw));
        self.cleanups += 1;
    }
    fn code(_: *anyopaque) c_int {
        return 0;
    }
    fn onRead(raw: ?*anyopaque, packets: helpers.Packets, _: ?[]const io.SocketAddress) anyerror!helpers.ReadAction {
        const self: *Mock = @ptrCast(@alignCast(raw.?));
        self.reads += 1;
        try std.testing.expectEqualStrings("x", packets[0]);
        try std.testing.expectError(error.ReentrantCall, self.loop.detach(.tun));
        try std.testing.expectError(error.ReentrantCall, self.loop.stop());
        return .pause;
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

test "looper inline reads writes retries and synchronous detach" {
    const wake = try WakeMux.init();
    defer wake.deinit();
    const loop = try Looper.create(allocator, .{
        .mux = wake.handle,
    });
    defer loop.destroy();
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var mock = Mock{ .fd = fds[0], .loop = loop };

    const args = helpers.AttachArguments{
        .pair = .{ .tun = mock.descriptor() },
        .on_read = .{ .context = &mock, .callback = Mock.onRead },
    };
    try loop.attach(args);
    try std.testing.expect(loop.isAttached(.tun));
    try std.testing.expect(!loop.isAttached(.link));
    try std.testing.expectError(error.SideAlreadyAttached, loop.attach(args));
    try std.testing.expectEqual(1, std.c.write(fds[1], "x", 1));
    try std.testing.expectEqual(0, mock.reads);
    wake.signal();
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try wake.reset();
    try std.testing.expectEqual(1, mock.reads);
    try loop.resumeReading(.tun);
    mock.backpressure = true;
    const packets: helpers.Packets = &.{"abc"};
    try loop.write(packets, .tun, null);
    try std.testing.expectEqual(0, mock.successful_writes);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(0, mock.successful_writes);
    try std.testing.expect(try test_helpers.poll(&loop, null));
    try std.testing.expectEqual(1, mock.successful_writes);
    const writes_before_queue = mock.writes;
    try loop.write(packets, .tun, null);
    try std.testing.expectEqual(writes_before_queue, mock.writes);
    try std.testing.expectEqual(1, mock.successful_writes);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(2, mock.successful_writes);
    mock.block = true;
    try loop.write(packets, .tun, null);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    const writes = mock.writes;
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(writes, mock.writes);
    try loop.detach(.tun);
    try std.testing.expectEqual(2, mock.successful_writes);
    try std.testing.expectEqual(1, mock.cleanups);
    try std.testing.expect(!loop.isAttached(.tun));
    try loop.stop();
}

test "timer callbacks can cancel and replace other ready tasks" {
    const Tasks = struct {
        loop: *Looper,
        cancel: helpers.Timer = .{},
        replace: helpers.Timer = .{},
        calls: usize = 0,
        fn edit(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.loop.cancelTimer(&self.cancel);
            self.loop.scheduleTimer(&self.replace, 0, .{ .context = self, .callback = called }) catch unreachable;
        }
        fn called(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
        }
    };
    const wake = try WakeMux.init();
    defer wake.deinit();
    const loop = try Looper.create(allocator, .{
        .mux = wake.handle,
    });
    defer loop.destroy();
    var tasks = Tasks{ .loop = loop };
    var first = helpers.Timer{};
    try loop.scheduleTimer(&first, 0, .{ .context = &tasks, .callback = Tasks.edit });
    try loop.scheduleTimer(&tasks.cancel, 0, .{ .context = &tasks, .callback = Tasks.called });
    try loop.scheduleTimer(&tasks.replace, 0, .{ .context = &tasks, .callback = Tasks.called });
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(0, tasks.calls);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(1, tasks.calls);
    // Tokens for already executed tasks remain harmless.
    loop.cancelTimer(&first);
    loop.cancelTimer(&tasks.replace);
}

test "write backpressure preserves an explicitly paused opposite side" {
    const wake = try WakeMux.init();
    defer wake.deinit();
    const loop = try Looper.create(allocator, .{
        .mux = wake.handle,
    });
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var link = Mock{ .fd = fds[0], .loop = loop };
    var tun = Mock{ .fd = fds[1], .loop = loop, .backpressure = true };
    // Keep borrowed callback contexts alive through destruction.
    defer loop.destroy();

    try loop.attach(.{
        .pair = .{ .link = link.descriptor() },
        .on_read = .{ .context = &link, .callback = Mock.onRead },
    });
    try loop.attach(.{
        .pair = .{ .tun = tun.descriptor() },
    });
    try std.testing.expectEqual(1, std.c.write(fds[1], "x", 1));
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(1, link.reads);
    link.has_read = false;
    try std.testing.expectEqual(1, std.c.write(fds[1], "x", 1));
    try loop.write(&.{"out"}, .tun, null);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expect(try test_helpers.poll(&loop, null));
    try std.testing.expectEqual(1, tun.successful_writes);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(1, link.reads);
    try loop.resumeReading(.link);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(2, link.reads);
    try loop.stop();
    try std.testing.expectEqual(1, link.cleanups);
    try std.testing.expectEqual(1, tun.cleanups);
}

test "caller mux wake interrupts an idle loop and survives looper destruction" {
    const Producer = struct {
        extern "c" fn usleep(c_uint) c_int;
        fn signal(wake: WakeMux) void {
            _ = usleep(20_000);
            wake.signal();
        }
    };
    var probe = Probe{};
    const wake = try WakeMux.init();
    defer wake.deinit();
    const loop = try Looper.create(allocator, .{
        .mux = wake.handle,
    });
    var destroyed = false;
    defer if (!destroyed) loop.destroy();
    probe.looper = loop;
    // A watchdog makes a missing wake fail without hanging the test suite.
    try loop.scheduleTimer(&probe.timer, 2000, .{ .context = &probe, .callback = Probe.task });
    const producer = try std.Thread.spawn(.{}, Producer.signal, .{wake});
    const continued = try test_helpers.poll(&loop, null);
    producer.join();
    try std.testing.expect(continued);
    try std.testing.expectEqual(0, probe.tasks);
    loop.cancelTimer(&probe.timer);

    var fd = [_]std.c.pollfd{.{ .fd = io.io_c.pp_mux_wake_descriptor(wake.handle), .events = std.c.POLL.IN, .revents = 0 }};
    // The shared mux consumes its wake while returning control to the owner.
    try std.testing.expectEqual(0, std.c.poll(&fd, 1, 0));
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try wake.reset();
    try std.testing.expectEqual(0, std.c.poll(&fd, 1, 0));
    try loop.stop();
    loop.destroy();
    destroyed = true;
    wake.signal();
    try wake.reset();
}

test "looper borrows its mux across allocation failure and replacement" {
    const mux = try WakeMux.init();
    defer mux.deinit();
    var probe = Probe{};
    const options = helpers.Options{
        .mux = mux.handle,
    };
    try std.testing.expectError(error.MuxFailure, Looper.create(allocator, .{
        .mux = null,
    }));
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Looper.create(failing.allocator(), options));
    for (0..2) |_| {
        const loop = try Looper.create(allocator, options);
        {
            defer loop.destroy();
            probe.looper = loop;
            try loop.scheduleTimer(&probe.timer, 0, .{ .context = &probe, .callback = Probe.task });
            try std.testing.expect(try test_helpers.poll(&loop, 0));
        }
        mux.signal();
        try std.testing.expect(io.io_c.pp_mux_wait(mux.handle, 0, null) > 0);
    }
    try std.testing.expectEqual(@as(usize, 2), probe.tasks);
}
