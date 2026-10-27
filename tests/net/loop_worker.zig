// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const source = @import("source");
const NativeRuntime = @import("../native_runtime.zig").NativeRuntime;
const io = source.net_io;
const net = source.net;
const core = source.core;
const api = core.api;
const Worker = source.net_connection_worker.ConnectionWorker;
const mock = source.mock;
const c = source.ffi.io;

const request: Worker.Request = .{
    .request_id = 1,
    .action = .start,
    .local_port = 0,
    .reachability = null,
    .connect_udp = false,
    .dns_timeout = 1000,
    .link_activity_timeout = 1000,
};

test "backend thread hooks bracket owned threads and foreign writers retain buffer ownership" {
    if (comptime builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    const native_runtime = try NativeRuntime.init();
    defer native_runtime.deinit();
    const Probe = struct {
        socket: io.LinkDescriptor,
        destination: io.SocketAddress,
        before: [2]i32 = .{ -1, -1 },
        during: [2]i32 = .{ -1, -1 },
        after: [2]i32 = .{ -1, -1 },
        entered: bool = false,
        writes: [3]i32 = .{ -1, -1, -1 },
        received: std.atomic.Value(u8) = .init(0),

        extern "ole32" fn CoGetApartmentType(*i32, *i32) callconv(.winapi) i32;

        fn apartment() [2]i32 {
            var result: [2]i32 = .{ -1, -1 };
            if (CoGetApartmentType(&result[0], &result[1]) < 0) return .{ -1, -1 };
            return result;
        }

        fn run(self: *@This()) void {
            self.before = apartment();
            var payload = [_]u8{'a'};
            // No entry hook: this models a foreign Go writer using the runtime's MTA.
            self.writes[0] = self.socket.write(&payload, self.destination);
            io.threadEnter() catch return;
            self.entered = true;
            self.during = apartment();
            payload[0] = 'b';
            self.writes[1] = self.socket.write(&payload, self.destination);
            io.threadExit();
            self.after = apartment();
            payload[0] = 'c';
            self.writes[2] = self.socket.write(&payload, self.destination);
            payload[0] = 'x'; // Each submitted Buffer must already own its payload.
        }

        fn receive(raw: ?*anyopaque, bytes: [*c]const u8, length: usize, _: [*c]const io.SocketAddress, code: i32) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const bit: u8 = if (code != 0 or length != 1) 8 else switch (bytes[0]) {
                'a' => 1,
                'b' => 2,
                'c' => 4,
                else => 8,
            };
            _ = self.received.fetchOr(bit, .release);
            return true;
        }
    };
    const receiver = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.SocketFailed;
    defer receiver.destroy();
    const sender = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.SocketFailed;
    defer sender.destroy();
    var probe = Probe{
        .socket = sender,
        .destination = try io.testing.socketAddress(.{ .address = "127.0.0.1", .proto = .init(.udp, (try receiver.localAddress()).port) }),
    };
    try receiver.setOnReceive(Probe.receive, &probe);
    defer receiver.setOnReceive(null, null) catch unreachable;
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();
    try std.testing.expect(probe.entered);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, probe.writes);
    // APTTYPE_MTA=1; qualifier is IMPLICIT_MTA=1 before/after, NONE=0 while entered.
    try std.testing.expectEqual([2]i32{ 1, 1 }, probe.before);
    try std.testing.expectEqual([2]i32{ 1, 0 }, probe.during);
    try std.testing.expectEqual(probe.before, probe.after);
    const deadline = core.monotonicNs() + 5 * std.time.ns_per_s;
    while (probe.received.load(.acquire) != 7) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
}

test "native receive removal drains the ABI callback before replacing its context" {
    if (comptime builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    const native_runtime = try NativeRuntime.init();
    defer native_runtime.deinit();
    const Probe = struct {
        calls: std.atomic.Value(usize) = .init(0),
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),

        fn receive(raw: ?*anyopaque, _: [*c]const u8, _: usize, _: [*c]const io.SocketAddress, _: i32) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.calls.fetchAdd(1, .monotonic);
            self.entered.store(true, .release);
            while (!self.released.load(.acquire)) core.sleepMs(1);
            return true;
        }
    };
    const Remove = struct {
        socket: io.LinkDescriptor,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.socket.setOnReceive(null, null) catch unreachable;
            self.done.store(true, .release);
        }
    };
    const receiver = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.SocketFailed;
    defer receiver.destroy();
    const sender = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.SocketFailed;
    defer sender.destroy();
    var probe = Probe{};
    defer probe.released.store(true, .release);
    try receiver.setOnReceive(Probe.receive, &probe);
    const destination = try io.testing.socketAddress(.{ .address = "127.0.0.1", .proto = .init(.udp, (try receiver.localAddress()).port) });
    try std.testing.expectEqual(@as(i32, 0), sender.write("first", destination));
    const deadline = core.monotonicNs() + 5 * std.time.ns_per_s;
    while (!probe.entered.load(.acquire)) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    var removal = Remove{ .socket = receiver };
    const thread = try std.Thread.spawn(.{}, Remove.run, .{&removal});
    defer {
        probe.released.store(true, .release);
        thread.join();
    }
    while (!removal.started.load(.acquire)) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    // Removal must wait for the native callback, independently of RuntimeLoop.
    core.sleepMs(20);
    try std.testing.expect(!removal.done.load(.acquire));
    probe.released.store(true, .release);
    while (!removal.done.load(.acquire)) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    var replacement = Probe{};
    replacement.released.store(true, .release);
    try receiver.setOnReceive(Probe.receive, &replacement);
    defer receiver.setOnReceive(null, null) catch unreachable;
    try std.testing.expectEqual(@as(i32, 0), sender.write("replacement", destination));
    while (!replacement.entered.load(.acquire)) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), replacement.calls.load(.acquire));
}

test "native setup requires an owner and runtime shutdown permits recreation" {
    if (comptime builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    try std.testing.expect(c.winrt_loop_current() == null);
    try std.testing.expect(c.winrt_connect("127.0.0.1", 9, &.{ .unconnected = false, .timeout_ms = 1000 }) == null);
    const Probe = struct {
        done: bool = false,
        fn run(raw: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.done = true;
        }
    };
    for (0..3) |_| {
        var probe = Probe{};
        {
            const native_runtime = try NativeRuntime.init();
            defer native_runtime.deinit();
            const loop = c.winrt_loop_current().?;
            // A failed second owner must leave the active runtime untouched.
            try std.testing.expect(c.winrt_loop_create() == null);
            try std.testing.expectEqual(loop, c.winrt_loop_current().?);
            {
                const socket = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.SocketFailed;
                defer socket.cleanup(); // Destruction is queued on the borrowed loop.
                try std.testing.expectEqual(@as(i32, 0), socket.write("queued", try io.testing.socketAddress(.{ .address = "127.0.0.1", .proto = .init(.udp, 9) })));
            }
            try std.testing.expect(c.winrt_loop_submit(loop, Probe.run, &probe));
        }
        // Owner shutdown joins queued commands and leaves no active loop.
        try std.testing.expect(probe.done);
        try std.testing.expect(c.winrt_loop_current() == null);
    }
}

test "runtime-owned loop outlives preparation worker and serves borrowed transports" {
    const native_runtime = try NativeRuntime.init();
    defer native_runtime.deinit();
    if (comptime builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    const Probe = struct {
        factory_thread: std.Thread.Id = 0,
        socket_thread: std.Thread.Id = 0,
        completion_thread: std.Thread.Id = 0,
        result: ?Worker.Completion = null,
        done: std.atomic.Value(bool) = .init(false),

        fn configure(raw: ?*anyopaque, _: c.pp_socket_fd, _: [*c]const c.pp_reachability) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.socket_thread = std.Thread.getCurrentId();
            return true;
        }
        fn socket(raw: ?*anyopaque, allocator: std.mem.Allocator, _: ?api.ExtendedEndpoint, _: u16, _: ?io.ReachabilityInfo, _: c_int) net.SocketFactory.Error!io.LinkDescriptor {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.factory_thread = std.Thread.getCurrentId();
            return (try io.SocketWrapper.create(allocator, null, .{
                .ipv4 = true,
                .ipv6 = false,
                .configure = configure,
                .configure_ctx = self,
            })) orelse error.LinkNotActive;
        }
        fn completed(raw: *anyopaque, context: *anyopaque, result: Worker.Completion) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(context == raw);
            self.completion_thread = std.Thread.getCurrentId();
            self.result = result;
            self.done.store(true, .release);
        }
    };
    var probe = Probe{};
    var table = mock.noopSocketFactory().vtable.*;
    table.create = Probe.socket;
    const worker = try Worker.create(std.testing.allocator, mock.noopDNSResolver(), .{ .ptr = &probe, .vtable = &table }, null, .{ .context = &probe, .call = Probe.completed });
    var destroyed = false;
    defer if (!destroyed) worker.destroy();
    try worker.submit(request, &probe);
    const deadline = core.monotonicNs() + 5 * std.time.ns_per_s;
    while (!probe.done.load(.acquire)) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    const result = probe.result.?;
    defer result.deinit();
    const remote = try result.remote;
    try std.testing.expectEqual(request.request_id, result.request_id);
    try std.testing.expectEqual(request.action, result.action);
    try std.testing.expect(probe.factory_thread != std.Thread.getCurrentId());
    try std.testing.expectEqual(probe.factory_thread, probe.socket_thread);
    try std.testing.expectEqual(probe.factory_thread, probe.completion_thread);
    worker.destroy();
    destroyed = true;
    // Destroying the preparation worker leaves the runtime's loop available.
    const address = try remote.link.?.localAddress();
    try std.testing.expectEqual(remote.local_port, address.port);
    try std.testing.expect(address.port != 0);
    try remote.link.?.resumeReading();
}

test "RuntimeLoop close drains each accepted completion and rejects new requests" {
    const native_runtime = try NativeRuntime.init();
    defer native_runtime.deinit();
    if (comptime builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    const Probe = struct {
        started: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        count: usize = 0,
        results: [2]?Worker.Completion = .{ null, null },
        fn socket(raw: ?*anyopaque, _: std.mem.Allocator, _: ?api.ExtendedEndpoint, _: u16, _: ?io.ReachabilityInfo, _: c_int) net.SocketFactory.Error!io.LinkDescriptor {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.started.store(true, .release);
            while (!self.released.load(.acquire)) core.sleepMs(1);
            return error.LinkNotActive;
        }
        fn completed(raw: *anyopaque, _: *anyopaque, result: Worker.Completion) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.results[self.count] = result;
            self.count += 1;
        }
    };
    var probe = Probe{};
    var table = mock.noopSocketFactory().vtable.*;
    table.create = Probe.socket;
    const worker = try Worker.create(std.testing.allocator, mock.noopDNSResolver(), .{ .ptr = &probe, .vtable = &table }, null, .{ .context = &probe, .call = Probe.completed });
    var destroyed = false;
    defer if (!destroyed) {
        probe.released.store(true, .release);
        worker.destroy();
    };
    try worker.submit(request, &probe);
    const deadline = core.monotonicNs() + 5 * std.time.ns_per_s;
    while (!probe.started.load(.acquire)) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    var second = request;
    second.request_id = 2;
    second.action = .rebind;
    try worker.submit(second, &probe);
    worker.close();
    try std.testing.expectError(error.Closed, worker.submit(request, &probe));
    probe.released.store(true, .release);
    worker.destroy();
    destroyed = true;
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    try std.testing.expectEqual(@as(u64, 1), probe.results[0].?.request_id);
    try std.testing.expectError(error.LinkNotActive, probe.results[0].?.remote);
    try std.testing.expectEqual(@as(u64, 2), probe.results[1].?.request_id);
    try std.testing.expectEqual(Worker.Action.rebind, probe.results[1].?.action);
    try std.testing.expectError(error.Closed, probe.results[1].?.remote);
}

test "RuntimeLoop transport teardown does not wait for a blocked rebind" {
    const native_runtime = try NativeRuntime.init();
    defer native_runtime.deinit();
    if (comptime builtin.os.tag != .windows or !source.winrt_enabled) return error.SkipZigTest;
    const Probe = struct {
        calls: usize = 0,
        first: ?Worker.Completion = null,
        completions: std.atomic.Value(usize) = .init(0),
        started: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),

        fn socket(raw: ?*anyopaque, allocator: std.mem.Allocator, _: ?api.ExtendedEndpoint, _: u16, _: ?io.ReachabilityInfo, _: c_int) net.SocketFactory.Error!io.LinkDescriptor {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.calls == 1) return (try io.SocketWrapper.create(allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse error.LinkNotActive;
            self.started.store(true, .release);
            while (!self.released.load(.acquire)) core.sleepMs(1);
            return error.LinkNotActive;
        }
        fn completed(raw: *anyopaque, _: *anyopaque, completion: Worker.Completion) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (completion.request_id == 1) self.first = completion else completion.deinit();
            _ = self.completions.fetchAdd(1, .release);
        }
        fn receive(_: ?*anyopaque, _: [*c]const u8, _: usize, _: [*c]const io.SocketAddress, _: i32) callconv(.c) bool {
            return true;
        }
    };
    const Stop = struct {
        link: io.LinkDescriptor,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.link.stopWrites();
            self.link.setOnReceive(null, null) catch unreachable;
            self.link.cleanup();
            self.done.store(true, .release);
        }
    };
    var probe = Probe{};
    var table = mock.noopSocketFactory().vtable.*;
    table.create = Probe.socket;
    const worker = try Worker.create(std.testing.allocator, mock.noopDNSResolver(), .{ .ptr = &probe, .vtable = &table }, null, .{ .context = &probe, .call = Probe.completed });
    defer {
        probe.released.store(true, .release);
        worker.destroy();
    }
    try worker.submit(request, &probe);
    const deadline = core.monotonicNs() + 5 * std.time.ns_per_s;
    while (probe.completions.load(.acquire) == 0) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    const remote = try probe.first.?.remote;
    var owned_link = remote.link;
    defer if (owned_link) |link| link.cleanup();
    try remote.link.?.setOnReceive(Probe.receive, null);
    var second = request;
    second.request_id = 2;
    second.action = .rebind;
    try worker.submit(second, &probe);
    while (!probe.started.load(.acquire)) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    // Commands admitted before teardown must remain safe until setup unblocks.
    const destination = try io.testing.socketAddress(.{ .address = "127.0.0.1", .proto = .init(.udp, 9) });
    try std.testing.expectEqual(@as(i32, 0), remote.link.?.write("queued", destination));
    var stop = Stop{ .link = remote.link.? };
    const thread = try std.Thread.spawn(.{}, Stop.run, .{&stop});
    owned_link = null; // The stopping caller owns the link from this point.
    while (!stop.done.load(.acquire) and core.monotonicNs() < deadline) core.sleepMs(1);
    const finished_while_blocked = stop.done.load(.acquire);
    // Release before joining so a regression reports a failure instead of hanging.
    probe.released.store(true, .release);
    thread.join();
    try std.testing.expect(finished_while_blocked);
    while (probe.completions.load(.acquire) != 2) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
}
