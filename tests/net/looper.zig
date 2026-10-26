// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const source = @import("source");
const test_helpers = @import("looper_test_helpers.zig");

const io = source.net_io;
const Looper = source.net_looper.Looper;

const TimerProbe = struct {
    calls: usize = 0,
    caller_thread: std.Thread.Id,
    ran_on_caller: bool = false,

    fn run(raw: ?*anyopaque) void {
        const self: *TimerProbe = @ptrCast(@alignCast(raw.?));
        self.ran_on_caller = self.caller_thread == std.Thread.getCurrentId();
        self.calls += 1;
    }
};

test "looper runs and cancels timers on its caller" {
    const wake: ?test_helpers.Mux = if (builtin.os.tag == .windows) null else try test_helpers.Mux.init();
    defer if (wake) |value| value.deinit();
    var looper = try Looper.init(std.testing.allocator, .{
        .mux = if (wake) |value| value.handle else null,
    });
    defer looper.deinit();
    var timer = io.Timer{};
    var probe = TimerProbe{ .caller_thread = std.Thread.getCurrentId() };
    const task: io.TimedTask = .{ .context = &probe, .callback = TimerProbe.run };
    try looper.scheduleTimer(&timer, 1, task);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expect(try test_helpers.poll(&looper, 100));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.ran_on_caller);

    try looper.scheduleTimer(&timer, 0, task);
    looper.cancelTimer(&timer);
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try looper.scheduleTimer(&timer, 1000, task);
    try looper.scheduleTimer(&timer, 0, task);
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);

    try looper.scheduleTimer(&timer, 0, task);
    try looper.stop();
    try looper.stop();
    try std.testing.expect(!try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectError(error.LooperUnavailable, looper.scheduleTimer(&timer, 0, task));
}

test "Windows timer callback can cancel a due task and rearm for the next iteration" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Probe = struct {
        looper: *Looper,
        first: io.Timer = .{},
        other: io.Timer = .{},
        calls: usize = 0,
        other_calls: usize = 0,

        fn run(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.looper.cancelTimer(&self.other);
            if (self.calls == 1) {
                self.looper.scheduleTimer(&self.first, 0, .{ .context = self, .callback = run }) catch unreachable;
            }
        }

        fn otherRun(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.other_calls += 1;
        }
    };
    var looper = try Looper.init(std.testing.allocator, .{ .mux = null });
    defer looper.deinit();
    var probe = Probe{ .looper = &looper };
    try looper.scheduleTimer(&probe.first, 0, .{ .context = &probe, .callback = Probe.run });
    try looper.scheduleTimer(&probe.other, 0, .{ .context = &probe, .callback = Probe.otherRun });
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.other_calls);
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
}

test "Windows dispatcher waits for the earlier timer deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var looper = try Looper.init(std.testing.allocator, .{ .mux = null });
    defer looper.deinit();
    var later = io.Timer{};
    var earlier = io.Timer{};
    var probe = TimerProbe{ .caller_thread = std.Thread.getCurrentId() };
    const task: io.TimedTask = .{ .context = &probe, .callback = TimerProbe.run };
    try looper.scheduleTimer(&later, 5000, task);
    try looper.scheduleTimer(&earlier, 10, task);
    const start = source.core.monotonicNs();
    try std.testing.expect(try test_helpers.poll(&looper, 2000));
    const elapsed = source.core.monotonicNs() - start;
    // A generous bound distinguishes the timer deadline from the poll timeout.
    try std.testing.expect(elapsed < std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.ran_on_caller);
    looper.cancelTimer(&later);
}

test "Windows dispatcher shares the daemon wake event without spinning or losing a wake" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const c = source.ffi.io;
    const mux = c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer c.pp_mux_free(mux);
    var looper = try Looper.init(std.testing.allocator, .{ .mux = mux });
    defer looper.deinit();

    // Commands already queued before entering the wait must remain observable.
    try std.testing.expect(c.pp_mux_wake(mux));
    try std.testing.expect(try test_helpers.poll(&looper, null));

    const Probe = struct {
        loop: *Looper,
        entered: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        alive: bool = false,
        failure: ?io.Failure = null,

        fn run(self: *@This()) void {
            self.entered.store(true, .release);
            self.alive = self.loop.loopOnce(&self.failure);
            self.done.store(true, .release);
        }
    };
    var probe = Probe{ .loop = &looper };
    const worker = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    defer {
        _ = c.pp_mux_wake(mux);
        worker.join();
    }
    for (0..5000) |_| {
        if (probe.entered.load(.acquire)) break;
        source.core.sleepMs(1);
    }
    try std.testing.expect(probe.entered.load(.acquire));
    source.core.sleepMs(20);
    try std.testing.expect(!probe.done.load(.acquire));
    try std.testing.expect(c.pp_mux_wake(mux));
    for (0..5000) |_| {
        if (probe.done.load(.acquire)) break;
        source.core.sleepMs(1);
    }
    try std.testing.expect(probe.done.load(.acquire));
    try std.testing.expect(probe.alive);
    try std.testing.expect(probe.failure == null);
}

test "Windows timer replacement failure preserves the old task and token" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var looper = try Looper.init(failing.allocator(), .{ .mux = null });
    defer looper.deinit();
    var timer = io.Timer{};
    var probe = TimerProbe{ .caller_thread = std.Thread.getCurrentId() };
    try looper.scheduleTimer(&timer, 0, .{ .context = &probe, .callback = TimerProbe.run });
    const old_id = timer.id;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, looper.scheduleTimer(&timer, 1000, .{
        .context = &probe,
        .callback = TimerProbe.run,
    }));
    try std.testing.expectEqual(old_id, timer.id);
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.ran_on_caller);
}

test "Windows timer expiry cannot invoke a context after cancellation or stop" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var looper = try Looper.init(std.testing.allocator, .{ .mux = null });
    defer looper.deinit();
    var probe = TimerProbe{ .caller_thread = std.Thread.getCurrentId() };
    // The scheduler stores the token value, not this temporary's address.
    var copied: io.Timer = timer: {
        var temporary = io.Timer{};
        try looper.scheduleTimer(&temporary, 1, .{ .context = &probe, .callback = TimerProbe.run });
        break :timer temporary;
    };
    source.core.sleepMs(20);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    looper.cancelTimer(&copied);
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try looper.scheduleTimer(&copied, 0, .{ .context = &probe, .callback = TimerProbe.run });
    try looper.stop();
    try std.testing.expect(!try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

const WindowsWriteProbe = struct {
    looper: *Looper,
    failures: usize = 0,
    code: ?c_int = null,
    detach_on_failure: bool = true,

    fn failed(context: ?*anyopaque, failure: io.Failure) void {
        const self: *WindowsWriteProbe = @ptrCast(@alignCast(context.?));
        self.failures += 1;
        self.code = failure.io.code;
        if (self.detach_on_failure) self.looper.detach(.link) catch unreachable;
    }
};

test "Windows looper owns sides and routes socket write failure" {
    if (builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    var looper = try Looper.init(std.testing.allocator, .{ .mux = null });
    defer looper.deinit();
    const socket = (try io.SocketWrapper.create(std.testing.allocator, null, .{
        .ipv4 = true,
        .ipv6 = false,
    })) orelse return error.SkipZigTest;
    var transferred = false;
    defer if (!transferred) socket.destroy();
    var probe = WindowsWriteProbe{ .looper = &looper };
    const packets = [_]io.Packet{"payload"};
    try std.testing.expect(!looper.isLinkAttached());
    try std.testing.expect(!looper.isTunAttached());
    try std.testing.expectError(error.SideNotAttached, looper.write(&packets, .link, null));
    try looper.attach(.{
        .pair = .{ .link = socket },
        .on_failure = .{ .context = &probe, .callback = WindowsWriteProbe.failed },
    });
    transferred = true;
    try std.testing.expect(looper.isLinkAttached());
    try std.testing.expect(!looper.isTunAttached());
    try std.testing.expectError(error.SideAlreadyAttached, looper.attach(.{ .pair = .{ .link = socket } }));
    try std.testing.expectError(error.MissingDestination, looper.write(&packets, .link, null));
    // IPv6 is invalid for this IPv4-only socket. Failure dispatch waits for poll.
    var destination = std.mem.zeroes(io.SocketAddress);
    destination.family = 6;
    destination.address[15] = 1;
    destination.port = 1194;
    try looper.write(&packets, .link, destination);
    try std.testing.expectEqual(@as(usize, 0), probe.failures);
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 1), probe.failures);
    try std.testing.expect(probe.code != null);
    try std.testing.expect(!looper.isLinkAttached());
    try std.testing.expect((try looper.flushWrites(.link)) == null);
}

const WindowsRejectedReceiver = struct {
    calls: usize = 0,

    fn receive(raw: ?*anyopaque, _: [*c]const u8, _: usize, _: [*c]const io.SocketAddress, _: i32) callconv(.c) bool {
        const self: *WindowsRejectedReceiver = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return false;
    }
};

test "Windows native write failures return asynchronously through the looper" {
    if (builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    var looper = try Looper.init(std.testing.allocator, .{ .mux = null });
    defer looper.deinit();
    const socket = (try io.SocketWrapper.create(std.testing.allocator, null, .{
        .ipv4 = true,
        .ipv6 = false,
    })) orelse return error.SocketFailed;
    var transferred = false;
    defer if (!transferred) socket.destroy();
    var probe = WindowsWriteProbe{ .looper = &looper, .detach_on_failure = false };
    var rejected: WindowsRejectedReceiver = .{};
    try looper.attach(.{
        .pair = .{ .link = socket },
        .on_failure = .{ .context = &probe, .callback = WindowsWriteProbe.failed },
    });
    transferred = true;
    // A rejected duplicate registration must preserve the original callback/context.
    try std.testing.expectError(error.ReceiveSetupFailed, socket.setOnReceive(WindowsRejectedReceiver.receive, &rejected));
    var destination = std.mem.zeroes(io.SocketAddress);
    destination.family = 4;
    destination.address[0] = 127;
    destination.address[3] = 1;
    destination.port = 1194;
    // Too large for UDP: submission owns the bytes, native completion fails.
    const payload = [_]u8{0} ** 65536;
    try std.testing.expectEqual(@as(i32, 0), socket.write(&payload, destination));
    try std.testing.expectEqual(@as(usize, 0), probe.failures);
    for (0..5000) |_| {
        if (probe.failures != 0) break;
        try std.testing.expect(try test_helpers.poll(&looper, 1));
    }
    try std.testing.expectEqual(@as(usize, 1), probe.failures);
    try std.testing.expectEqual(@as(usize, 0), rejected.calls);
    try std.testing.expect(probe.code.? != 0);
    // A terminal failure remains visible to subsequent submissions, until stop
    // replaces it with cancellation. Neither path restarts the native writer.
    const failed = socket.write("after failure", destination);
    try std.testing.expectEqual(probe.code.?, failed);
    socket.stopWrites();
    const stopped = socket.write("after stop", destination);
    try std.testing.expectEqual(@as(i32, -2147467260), stopped); // E_ABORT
    try looper.detach(.link);
    try std.testing.expect(!looper.isLinkAttached());
}

const WindowsSockets = struct {
    extern "ws2_32" fn socket(c_int, c_int, c_int) callconv(.winapi) usize;
    extern "ws2_32" fn bind(usize, *const anyopaque, c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(usize, c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockname(usize, *anyopaque, *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(usize, ?*anyopaque, ?*c_int) callconv(.winapi) usize;
    extern "ws2_32" fn setsockopt(usize, c_int, c_int, *const anyopaque, c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recv(usize, [*]u8, c_int, c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn send(usize, [*]const u8, c_int, c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(usize) callconv(.winapi) c_int;
};

const WindowsDetachProbe = struct {
    looper: *Looper,
    caller_thread: std.Thread.Id,
    ran_on_caller: bool = false,
    detached: bool = false,
    failures: usize = 0,
    reads: usize = 0,

    fn read(context: ?*anyopaque, _: io.Packets, _: ?[]const io.SocketAddress) anyerror!io.ReadAction {
        const self: *WindowsDetachProbe = @ptrCast(@alignCast(context.?));
        self.ran_on_caller = self.caller_thread == std.Thread.getCurrentId();
        self.reads += 1;
        if (self.reads == 1) return .pause;
        if (self.reads == 2) return .keep;
        try self.looper.detach(.link);
        self.detached = true;
        return .keep;
    }
    fn failed(context: ?*anyopaque, _: io.Failure) void {
        const self: *WindowsDetachProbe = @ptrCast(@alignCast(context.?));
        self.failures += 1;
    }
};

test "Windows TCP receive resumes and detaches its side on the looper thread" {
    if (builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    const c = source.ffi.io;
    const ws = WindowsSockets;
    // Initialize Winsock using the native backend, then make a local TCP peer.
    const startup = c.pp_socket_open("127.0.0.1", c.PPSocketProtoUDP, 9, &.{ .timeout_ms = 1000 }) orelse return error.SocketFailed;
    defer c.pp_socket_free(startup);
    const listener = ws.socket(2, 1, 6);
    try std.testing.expect(listener != std.math.maxInt(usize));
    defer _ = ws.closesocket(listener);
    var address = std.os.windows.ws2_32.sockaddr.in{
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try std.testing.expect(ws.bind(listener, &address, @sizeOf(@TypeOf(address))) == 0);
    try std.testing.expect(ws.listen(listener, 1) == 0);
    var address_length: c_int = @sizeOf(@TypeOf(address));
    try std.testing.expect(ws.getsockname(listener, &address, &address_length) == 0);
    const socket = (try io.SocketWrapper.create(std.testing.allocator, .{
        .address = "127.0.0.1",
        .proto = .init(.tcp, std.mem.bigToNative(u16, address.port)),
    }, .{ .timeout_ms = 5000 })) orelse return error.SkipZigTest;
    var transferred = false;
    defer if (!transferred) socket.destroy();
    const peer = ws.accept(listener, null, null);
    try std.testing.expect(peer != std.math.maxInt(usize));
    defer _ = ws.closesocket(peer);
    const timeout: u32 = 5000;
    try std.testing.expect(ws.setsockopt(peer, 65535, 0x1006, &timeout, @sizeOf(u32)) == 0);
    var looper = try Looper.init(std.testing.allocator, .{ .mux = null });
    defer looper.deinit();
    var probe = WindowsDetachProbe{ .looper = &looper, .caller_thread = std.Thread.getCurrentId() };
    try looper.attach(.{
        .pair = .{ .link = socket },
        .on_read = .{ .context = &probe, .callback = WindowsDetachProbe.read },
        .on_failure = .{ .context = &probe, .callback = WindowsDetachProbe.failed },
    });
    transferred = true;
    // Queue a burst before the peer reads, reusing the caller's buffer each time.
    // Native completion must preserve both byte ownership and submission order.
    var outgoing: [16 * 1024]u8 = undefined;
    for (0..32) |index| {
        @memset(&outgoing, @intCast(index));
        try looper.write(&.{&outgoing}, .link, null);
    }
    @memset(&outgoing, 255);
    var incoming: [16 * 1024]u8 = undefined;
    var received: usize = 0;
    while (received < outgoing.len * 32) {
        const count = ws.recv(peer, &incoming, incoming.len, 0);
        try std.testing.expect(count > 0);
        for (incoming[0..@intCast(count)]) |byte| {
            try std.testing.expectEqual(@as(u8, @intCast(received / outgoing.len)), byte);
            received += 1;
        }
    }
    try std.testing.expectEqual(@as(c_int, 1), ws.send(peer, "x", 1, 0));
    for (0..5000) |_| {
        if (probe.reads == 1) break;
        try std.testing.expect(try test_helpers.poll(&looper, 1));
    }
    try std.testing.expectEqual(@as(usize, 1), probe.reads);
    try std.testing.expectEqual(@as(c_int, 1), ws.send(peer, "y", 1, 0));
    // Receive while paused, then resume the consumer and the native read loop.
    try std.testing.expect(try test_helpers.poll(&looper, 20));
    try std.testing.expectEqual(@as(usize, 1), probe.reads);
    try looper.resumeReading(.link);
    for (0..5000) |_| {
        if (probe.reads == 2) break;
        try std.testing.expect(try test_helpers.poll(&looper, 1));
    }
    try std.testing.expectEqual(@as(usize, 2), probe.reads);
    try std.testing.expectEqual(@as(c_int, 1), ws.send(peer, "z", 1, 0));
    for (0..5000) |_| {
        if (probe.detached) break;
        try std.testing.expect(try test_helpers.poll(&looper, 1));
    }
    try std.testing.expect(probe.detached);
    try std.testing.expect(!looper.isLinkAttached());
    try std.testing.expect(probe.ran_on_caller);
    try std.testing.expectError(error.SideNotAttached, looper.write(&.{"after detach"}, .link, null));
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), ws.recv(peer, &buffer, buffer.len, 0));
    try std.testing.expectEqual(@as(usize, 0), probe.failures);
}

const WindowsAdmissionProbe = struct {
    reads: usize = 0,
    failures: usize = 0,

    fn read(raw: ?*anyopaque, packets: io.Packets, _: ?[]const io.SocketAddress) anyerror!io.ReadAction {
        const self: *WindowsAdmissionProbe = @ptrCast(@alignCast(raw.?));
        try std.testing.expectEqualStrings("resumed", packets[0]);
        self.reads += 1;
        return .keep;
    }

    fn failed(raw: ?*anyopaque, _: io.Failure) void {
        const self: *WindowsAdmissionProbe = @ptrCast(@alignCast(raw.?));
        self.failures += 1;
    }
};

test "Windows paused TUN drops new input but admits failures and resumes delivery" {
    if (builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    var looper = try Looper.init(std.testing.allocator, .{ .mux = null });
    defer looper.deinit();
    var probe: WindowsAdmissionProbe = .{};
    // Exercise admission/dispatch without a VPN host. This unattached side has
    // no native handle to drain or destroy; queued nodes retain it during dispatch.
    var side: Looper.Impl.testing.Side = .{
        .owner = looper.impl,
        .arguments = .{
            .pair = .{ .tun = undefined },
            .on_read = .{ .context = &probe, .callback = WindowsAdmissionProbe.read },
            .on_failure = .{ .context = &probe, .callback = WindowsAdmissionProbe.failed },
        },
        .reading = false,
    };
    for (0..10000) |_| {
        try std.testing.expect(!Looper.Impl.testing.receive(&side, "paused", 6, null, 0));
    }
    try std.testing.expectEqual(@as(u64, 10000), side.dropped);
    try std.testing.expectEqual(@as(u64, 0), side.queued);
    try std.testing.expect(looper.impl.callbacks.head == null);

    const native_failure: i32 = -2147467260; // E_ABORT
    try std.testing.expect(!Looper.Impl.testing.receive(&side, null, 0, null, native_failure));
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 1), probe.failures);
    try std.testing.expectEqual(@as(usize, 0), probe.reads);

    side.reading = true;
    try std.testing.expect(Looper.Impl.testing.receive(&side, "resumed", 7, null, 0));
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 1), probe.reads);
    try std.testing.expectEqual(@as(usize, 1), side.references);
    try std.testing.expect(looper.impl.callbacks.head == null);
}
