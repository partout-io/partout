// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const source = @import("source");
const NativeRuntime = @import("../native_runtime.zig").NativeRuntime;
const test_helpers = @import("looper_test_helpers.zig");
const io = source.net_io;
const Looper = source.net_looper.Looper;
const allocator = std.testing.allocator;
const Atomic = std.atomic.Value(usize);
const libc = struct {
    extern "c" fn close(std.c.fd_t) c_int;
};

const ReadProbe = struct {
    loop: *Looper,
    calls: Atomic = .init(0),
    total: Atomic = .init(0),
    first_count: usize = 0,
    last: [64]u8 = undefined,
    last_size: usize = 0,
    first_pointer: ?[*]const u8 = null,
    reused_storage: bool = true,
    caller_thread: std.Thread.Id,
    on_caller: bool = true,
    lifecycle_rejected: bool = false,
    pause: bool = false,
    fail_callback: bool = false,
    failure: ?io.Failure = null,
    failures: usize = 0,

    fn read(raw: ?*anyopaque, packets: io.Packets, addresses: ?[]const io.SocketAddress) anyerror!io.ReadAction {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.on_caller = self.on_caller and self.caller_thread == std.Thread.getCurrentId();
        try std.testing.expect(addresses == null);
        if (self.first_pointer) |pointer| {
            self.reused_storage = self.reused_storage and pointer == packets[0].ptr;
        } else self.first_pointer = packets[0].ptr;
        if (self.calls.load(.acquire) == 0) self.first_count = packets.len;
        for (packets) |packet| {
            @memcpy(self.last[0..packet.len], packet);
            self.last_size = packet.len;
        }
        self.loop.detach(.tun) catch |err| {
            self.lifecycle_rejected = err == error.ReentrantCall;
        };
        _ = self.total.fetchAdd(packets.len, .release);
        _ = self.calls.fetchAdd(1, .release);
        if (self.fail_callback) return error.ReadCallbackFailed;
        return if (self.pause) .pause else .keep;
    }

    fn failed(raw: ?*anyopaque, failure: io.Failure) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.failures += 1;
        self.failure = failure;
    }

    fn attach(self: *@This(), pair: io.DescriptorPair) Looper.AttachArguments {
        return .{
            .pair = pair,
            .on_read = .{ .context = self, .callback = read },
            .on_failure = .{ .context = self, .callback = failed },
        };
    }
};

const Mock = struct {
    fd: std.c.fd_t,
    output: [128]u8 = undefined,
    output_len: usize = 0,
    block_writes: bool = false,
    backpressure_once: bool = false,
    fail_read: bool = false,
    fail_read_after: ?usize = null,
    reads: usize = 0,
    read_capacity: usize = 0,
    partial_once: bool = false,
    fail_after: ?usize = null,
    writes: usize = 0,
    cleaned: usize = 0,

    fn read(raw: *anyopaque, data: []u8) io.Error!?usize {
        const self: *Mock = @ptrCast(@alignCast(raw));
        if (self.fail_read) return error.LibcFailure;
        if (self.fail_read_after) |count| if (self.reads >= count) return error.LibcFailure;
        var byte: [1]u8 = undefined;
        if (std.c.read(self.fd, &byte, 1) != 1) return error.WouldBlock;
        self.reads += 1;
        self.read_capacity = data.len;
        data[0] = byte[0];
        return 1;
    }
    fn write(raw: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
        const self: *Mock = @ptrCast(@alignCast(raw));
        if (self.block_writes) return error.WouldBlock;
        if (self.fail_after) |limit| if (self.writes >= limit) return error.LibcFailure;
        if (self.backpressure_once) {
            self.backpressure_once = false;
            return error.Backpressure;
        }
        if (self.partial_once) {
            self.partial_once = false;
            self.output[self.output_len] = data[offset];
            self.output_len += 1;
            return 1;
        }
        self.writes += 1;
        const remaining = data[offset..];
        @memcpy(self.output[self.output_len..][0..remaining.len], remaining);
        self.output_len += remaining.len;
        return remaining.len;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *Mock = @ptrCast(@alignCast(raw));
        self.cleaned += 1;
    }
    fn lastError(_: *anyopaque) c_int {
        return 0;
    }
    const vtable = source.net_io_posix.POSIXInterface.Mock.VTable{
        .read = read,
        .write = write,
        .cleanup = cleanup,
        .last_error_code = lastError,
    };

    fn pair(self: *Mock) io.DescriptorPair {
        return .{ .tun = .{ .fd = self.fd, .io = .{ .mock = .{ .ptr = self, .vtable = &vtable } } } };
    }
};

fn pipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    errdefer {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
    }
    const flags = std.c.fcntl(fds[0], std.c.F.GETFL, @as(c_int, 0));
    if (std.c.fcntl(fds[0], std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) < 0) return error.FcntlFailed;
    return fds;
}

fn closePipe(fds: [2]std.c.fd_t) void {
    _ = libc.close(fds[0]);
    _ = libc.close(fds[1]);
}

test "owned reads bound batches and drain remaining packets" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]io.Side{ .link, .tun }) |side| {
        for ([_]usize{ 256 * 1024, 8 }) |max_read_size| {
            for ([_]usize{ 128, 7 }) |max_read_count| {
                const fds = try pipe();
                defer closePipe(fds);
                const wake = try test_helpers.Mux.init();
                defer wake.deinit();
                var mock = Mock{ .fd = fds[0] };
                var loop = try Looper.init(allocator, .{
                    .mux = wake.handle,

                    .max_read_size = max_read_size,
                    .max_read_count = max_read_count,
                });
                defer loop.deinit();
                var probe = ReadProbe{ .loop = &loop, .caller_thread = std.Thread.getCurrentId() };
                const descriptor = mock.pair().tun;
                try loop.attach(probe.attach(switch (side) {
                    .link => .{ .link = descriptor },
                    .tun => .{ .tun = descriptor },
                }));
                const payload = [_]u8{'x'} ** 128;
                try std.testing.expectEqual(@as(isize, payload.len), std.c.write(fds[1], &payload, payload.len));
                try std.testing.expectEqual(@as(usize, 0), mock.reads);
                try test_helpers.wait(&loop, &probe.total, payload.len);
                try std.testing.expectEqual(@min(@as(usize, 16), max_read_count, max_read_size), probe.first_count);
                try std.testing.expectEqual(@as(usize, 64 * 1024), mock.read_capacity);
                try std.testing.expect(probe.on_caller and probe.reused_storage and probe.lifecycle_rejected);
                try loop.stop();
                try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
            }
        }
    }
}

test "reads reuse owned storage without allocating between iterations" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pipe();
    defer closePipe(fds);
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var loop = try Looper.init(failing.allocator(), .{
        .mux = wake.handle,

        .tun_buf_size = 16,
    });
    defer loop.deinit();
    var mock = Mock{ .fd = fds[0] };
    var probe = ReadProbe{ .loop = &loop, .caller_thread = std.Thread.getCurrentId() };
    try loop.attach(probe.attach(mock.pair()));
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    try test_helpers.wait(&loop, &probe.calls, 1);
    try std.testing.expectEqualStrings("x", probe.last[0..probe.last_size]);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "y", 1));
    try test_helpers.wait(&loop, &probe.calls, 2);
    try std.testing.expectEqualStrings("y", probe.last[0..probe.last_size]);
    try std.testing.expectEqual(@as(usize, 16), mock.read_capacity);
    try std.testing.expect(probe.reused_storage and probe.on_caller);
    try loop.stop();
}

test "copies write payloads and descriptors across partial writes and backpressure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pipe();
    defer closePipe(fds);
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var loop = try Looper.init(allocator, .{
        .mux = wake.handle,
    });
    defer loop.deinit();
    var mock = Mock{ .fd = fds[1], .partial_once = true, .backpressure_once = true };
    try loop.attach(.{ .pair = mock.pair() });
    var payload = "copied".*;
    var packets = [_]io.Packet{ &payload, "", "second" };
    try loop.write(&packets, .tun, null);
    @memset(&payload, 'x');
    packets = .{ "changed", "changed", "changed" };
    try std.testing.expectEqual(@as(usize, 0), mock.writes);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(@as(usize, 0), mock.writes);
    for (0..10) |_| {
        if (mock.writes == 3) break;
        try std.testing.expect(try test_helpers.poll(&loop, 100));
    }
    try std.testing.expectEqual(@as(usize, 3), mock.writes);
    try std.testing.expectEqualStrings("copiedsecond", mock.output[0..mock.output_len]);
    try loop.stop();
}

test "shutdown flush attempts writes without dispatching callbacks or waiting" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Mode = enum { writable, blocked, failed };
    for ([_]Mode{ .writable, .blocked, .failed }) |mode| {
        const fds = try pipe();
        defer closePipe(fds);
        const wake = try test_helpers.Mux.init();
        defer wake.deinit();
        var loop = try Looper.init(allocator, .{
            .mux = wake.handle,
        });
        defer loop.deinit();
        var mock = Mock{ .fd = fds[0], .block_writes = mode == .blocked, .fail_after = if (mode == .failed) 0 else null };
        var probe = ReadProbe{ .loop = &loop, .caller_thread = std.Thread.getCurrentId() };
        try loop.attach(probe.attach(mock.pair()));
        try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
        var timer: io.Timer = .{};
        var fired = false;
        try loop.scheduleTimer(&timer, 0, .{ .context = &fired, .callback = struct {
            fn call(raw: ?*anyopaque) void {
                const value: *bool = @ptrCast(@alignCast(raw.?));
                value.* = true;
            }
        }.call });
        try loop.write(&.{"exit"}, .tun, null);
        const failure = try loop.flushWrites(.tun);
        try std.testing.expectEqual(mode == .failed, failure != null);
        try std.testing.expectEqual(@as(usize, if (mode == .writable) 1 else 0), mock.writes);
        if (mode == .writable) try std.testing.expectEqualStrings("exit", mock.output[0..mock.output_len]);
        try std.testing.expect(!fired);
        try std.testing.expectEqual(@as(usize, 0), mock.reads);
        try std.testing.expectEqual(@as(usize, 0), probe.failures);
        try loop.detach(.tun);
        try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
    }
}

test "detach stop and destroy free pending write copies" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Action = enum { detach, stop, deinit };
    inline for (.{ Action.detach, Action.stop, Action.deinit }) |action| {
        const fds = try pipe();
        defer closePipe(fds);
        const wake = try test_helpers.Mux.init();
        defer wake.deinit();
        var loop = try Looper.init(allocator, .{
            .mux = wake.handle,
        });
        var destroyed = false;
        defer if (!destroyed) loop.deinit();
        var mock = Mock{ .fd = fds[0], .block_writes = true };
        try loop.attach(.{ .pair = mock.pair() });
        try loop.write(&.{ "pending", "also pending" }, .tun, null);
        try std.testing.expect(try test_helpers.poll(&loop, 0));
        switch (action) {
            .detach => try loop.detach(.tun),
            .stop => try loop.stop(),
            .deinit => {
                loop.deinit();
                destroyed = true;
            },
        }
        try std.testing.expectEqual(@as(usize, 0), mock.writes);
        try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
    }
}

test "read and callback failures report the cause and detach the side" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Failure = enum { io, partial, callback };
    for (std.enums.values(Failure)) |failure| {
        const fds = try pipe();
        defer closePipe(fds);
        const wake = try test_helpers.Mux.init();
        defer wake.deinit();
        var loop = try Looper.init(allocator, .{
            .mux = wake.handle,
        });
        defer loop.deinit();
        var mock = Mock{ .fd = fds[0], .fail_read = failure == .io, .fail_read_after = if (failure == .partial) 1 else null };
        var probe = ReadProbe{ .loop = &loop, .caller_thread = std.Thread.getCurrentId(), .fail_callback = failure == .callback };
        try loop.attach(probe.attach(mock.pair()));
        try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
        var reported_failure: ?io.Failure = null;
        try std.testing.expect(loop.impl.loopOnce(10, &reported_failure));
        try std.testing.expect(reported_failure != null);
        try std.testing.expect(!loop.isTunAttached());
        try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
        try std.testing.expectEqual(@as(usize, 1), probe.failures);
        try std.testing.expectEqual(@as(usize, if (failure == .io) 0 else 1), probe.total.load(.acquire));
        switch (failure) {
            .io, .partial => try std.testing.expectEqual(error.LibcFailure, probe.failure.?.io.cause),
            .callback => try std.testing.expectEqual(error.ReadCallbackFailed, probe.failure.?.user),
        }
    }
}

test "validates attachment sizes and write destinations before taking ownership" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pipe();
    defer closePipe(fds);
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var loop = try Looper.init(allocator, .{ .mux = wake.handle, .tun_buf_size = 0 });
    defer loop.deinit();
    var mock = Mock{ .fd = fds[0] };
    try std.testing.expectError(error.InvalidBuffers, loop.attach(.{ .pair = mock.pair() }));
    try std.testing.expectEqual(@as(usize, 0), mock.cleaned);
    try std.testing.expectError(error.SideNotAttached, loop.write(&.{"x"}, .tun, null));
    try loop.write(&.{}, .tun, null);
    try loop.stop();
    try std.testing.expectError(error.LooperUnavailable, loop.write(&.{"x"}, .tun, null));
}

test "initialization and owned read attachment roll back allocation failures" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Scenario = struct {
        fn run(test_allocator: std.mem.Allocator) !void {
            const fds = try pipe();
            defer closePipe(fds);
            const wake = try test_helpers.Mux.init();
            defer wake.deinit();
            var loop = try Looper.init(test_allocator, .{
                .mux = wake.handle,
            });
            defer loop.deinit();
            var mock = Mock{ .fd = fds[0] };
            loop.attach(.{ .pair = mock.pair() }) catch |err| {
                try std.testing.expect(!loop.isTunAttached());
                try std.testing.expectEqual(@as(usize, 0), mock.cleaned);
                return err;
            };
            try loop.stop();
            try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scenario.run, .{});
}

test "failed copied batches preserve already queued writes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // Each packet owns its copied payload and queue node.
    for (0..4) |successful_allocations| {
        const fds = try pipe();
        defer closePipe(fds);
        const wake = try test_helpers.Mux.init();
        defer wake.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var loop = try Looper.init(failing.allocator(), .{
            .mux = wake.handle,
        });
        defer loop.deinit();
        var mock = Mock{ .fd = fds[1] };
        try loop.attach(.{ .pair = mock.pair() });
        try loop.write(&.{"head"}, .tun, null);
        failing.fail_index = failing.alloc_index + successful_allocations;
        try std.testing.expectError(error.OutOfMemory, loop.write(&.{ "one", "two" }, .tun, null));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(try test_helpers.poll(&loop, 0));
        try std.testing.expectEqual(@as(usize, 1), mock.writes);
        try std.testing.expectEqualStrings("head", mock.output[0..mock.output_len]);
        try loop.stop();
    }
}

test "read callbacks pause until resumed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pipe();
    defer closePipe(fds);
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var loop = try Looper.init(allocator, .{ .mux = wake.handle, .max_read_count = 1 });
    defer loop.deinit();
    var mock = Mock{ .fd = fds[0] };
    var probe = ReadProbe{ .loop = &loop, .caller_thread = std.Thread.getCurrentId(), .pause = true };
    try loop.attach(probe.attach(mock.pair()));
    try std.testing.expectEqual(@as(isize, 2), std.c.write(fds[1], "xy", 2));
    try test_helpers.wait(&loop, &probe.calls, 1);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expectEqual(@as(usize, 1), mock.reads);
    try loop.resumeReading(.tun);
    try test_helpers.wait(&loop, &probe.calls, 2);
    try std.testing.expectEqualStrings("y", probe.last[0..probe.last_size]);
    try loop.stop();
}

test "write failure reports the cause and discards later queued copies" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pipe();
    defer closePipe(fds);
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var loop = try Looper.init(allocator, .{
        .mux = wake.handle,
    });
    defer loop.deinit();
    var mock = Mock{ .fd = fds[1], .fail_after = 1 };
    var probe = ReadProbe{ .loop = &loop, .caller_thread = std.Thread.getCurrentId() };
    try loop.attach(probe.attach(mock.pair()));
    try loop.write(&.{ "one", "two", "later" }, .tun, null);
    var reported_failure: ?io.Failure = null;
    try std.testing.expect(loop.impl.loopOnce(0, &reported_failure));
    try std.testing.expect(reported_failure != null);
    try std.testing.expectEqualStrings("one", mock.output[0..mock.output_len]);
    try std.testing.expectEqual(error.LibcFailure, probe.failure.?.io.cause);
    try std.testing.expectEqual(@as(usize, 1), probe.failures);
    try std.testing.expect(!loop.isTunAttached());
    try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
}

test "owned reads honor packet and byte limits across iterations" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |limit_bytes| {
        const fds = try pipe();
        defer closePipe(fds);
        const wake = try test_helpers.Mux.init();
        defer wake.deinit();
        var loop = try Looper.init(allocator, .{
            .mux = wake.handle,

            .max_read_count = if (limit_bytes) 2 else 1,
            .max_read_size = if (limit_bytes) 1 else 1024,
        });
        defer loop.deinit();
        var mock = Mock{ .fd = fds[0] };
        var probe = ReadProbe{ .loop = &loop, .caller_thread = std.Thread.getCurrentId() };
        try loop.attach(probe.attach(mock.pair()));
        try std.testing.expectEqual(@as(isize, 2), std.c.write(fds[1], "xy", 2));
        try std.testing.expect(try test_helpers.poll(&loop, 0));
        try std.testing.expectEqual(@as(usize, 1), probe.total.load(.acquire));
        try std.testing.expect(try test_helpers.poll(&loop, 0));
        try std.testing.expectEqual(@as(usize, 2), probe.total.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), probe.calls.load(.acquire));
        try loop.stop();
    }
}

test "reads without an observer drain data and still report failures" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |fail_read| {
        const fds = try pipe();
        defer closePipe(fds);
        const wake = try test_helpers.Mux.init();
        defer wake.deinit();
        var loop = try Looper.init(allocator, .{
            .mux = wake.handle,
        });
        defer loop.deinit();
        var mock = Mock{ .fd = fds[0], .fail_read = fail_read };
        var probe = ReadProbe{ .loop = &loop, .caller_thread = std.Thread.getCurrentId() };
        try loop.attach(.{ .pair = mock.pair(), .on_failure = .{ .context = &probe, .callback = ReadProbe.failed } });
        try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
        var reported_failure: ?io.Failure = null;
        try std.testing.expect(loop.impl.loopOnce(10, &reported_failure));
        try std.testing.expectEqual(fail_read, reported_failure != null);
        if (fail_read) {
            try std.testing.expectEqual(error.LibcFailure, probe.failure.?.io.cause);
            try std.testing.expect(!loop.isTunAttached());
        } else {
            try std.testing.expectEqual(@as(usize, 1), mock.reads);
            try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "y", 1));
            try std.testing.expect(try test_helpers.poll(&loop, 10));
            try std.testing.expectEqual(@as(usize, 2), mock.reads);
        }
        try std.testing.expectEqual(@as(usize, 0), probe.calls.load(.acquire));
        try loop.stop();
    }
}

test "UDP packet errors discard only the bad packet and retain the link" {
    const native_runtime = try NativeRuntime.init();
    defer native_runtime.deinit();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var loop = try Looper.init(allocator, .{
        .mux = wake.handle,
    });
    defer loop.deinit();
    const socket = (try io.SocketWrapper.create(allocator, null, .{})) orelse return error.SocketFailed;
    const peer = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
    defer peer.destroy();
    var remote = try peer.linkDescriptor().localAddress();
    remote.address[0..4].* = .{ 127, 0, 0, 1 };
    try loop.attach(.{ .pair = .{ .link = socket.linkDescriptor() } });
    try std.testing.expectError(error.MissingDestination, loop.write(&.{"x"}, .link, null));
    const oversized = [_]u8{0} ** 65535;
    try loop.write(&.{ &oversized, "valid" }, .link, remote);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    try std.testing.expect(loop.isLinkAttached());
    var bytes: [64]u8 = undefined;
    var sender: io.SocketAddress = undefined;
    const size = for (0..500) |_| {
        break (peer.linkDescriptor().io.readPacket(&bytes, &sender) catch |err| {
            if (err != error.WouldBlock) return err;
            try std.testing.expect(try test_helpers.poll(&loop, 10));
            continue;
        }) orelse return error.EndOfStream;
    } else return error.Timeout;
    try std.testing.expectEqualStrings("valid", bytes[0..size]);
    try std.testing.expect(loop.isLinkAttached());
    try loop.stop();
}
