// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const source = @import("source");
const io = source.net_io;
const net = source.net;
const core = source.core;
const api = core.api;
const Worker = source.net_connection_worker.RuntimeLoopWorker;
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

test "RuntimeLoop prepares and opens on one native thread and retains the transport" {
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
    // The returned capability retains the same worker for ongoing I/O.
    const address = try remote.link.?.localAddress();
    try std.testing.expectEqual(remote.local_port, address.port);
    try std.testing.expect(address.port != 0);
    try remote.link.?.resumeReading();
}

test "RuntimeLoop close drains each accepted completion and rejects new requests" {
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
