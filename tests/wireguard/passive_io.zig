// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const source = @import("source");
const bridge = source.wireguard_internal.passive_io;
const c = bridge.testing.abi;
const io = source.net_io;

const Completion = struct {
    calls: usize = 0,
    count: u32 = 0,
    status: i32 = 99,
    fn finish(request: usize, count: u32, status: i32) callconv(.c) void {
        const self: *Completion = @ptrFromInt(request);
        self.calls += 1;
        self.count = count;
        self.status = status;
    }
    fn token(self: *Completion) usize {
        return @intFromPtr(self);
    }
};

// Quarantine and zero freed storage so accessing a destroyed packet's slice
// cannot accidentally work because the allocator left its metadata intact.
const ClearingAllocator = struct {
    arena: std.heap.ArenaAllocator,
    frees: usize = 0,

    fn allocator(self: *ClearingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }
    fn alloc(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *ClearingAllocator = @ptrCast(@alignCast(raw));
        return self.arena.allocator().rawAlloc(length, alignment, ret);
    }
    fn free(raw: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *ClearingAllocator = @ptrCast(@alignCast(raw));
        self.frees += 1;
        @memset(memory, 0);
    }
};

test "WireGuard passive UDP preserves multiple peer sources and reply destinations" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    var clearing = ClearingAllocator{ .arena = .init(std.testing.allocator) };
    defer clearing.arena.deinit();
    var receiver = try bridge.PassiveIO.init(Completion.finish);
    receiver.allocator = clearing.allocator();
    defer receiver.deinit();
    var peers: [2]bridge.PassiveIO = .{ try .init(Completion.finish), try .init(Completion.finish) };
    defer for (&peers) |*peer| peer.deinit();
    const socket = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })).?;
    receiver.replaceLink(socket.linkDescriptor());
    var endpoint = std.mem.zeroes(c.wg_endpoint);
    endpoint.family = 4;
    endpoint.address[0] = 127;
    endpoint.address[3] = 1;
    endpoint.port = (try socket.linkDescriptor().localAddress()).port;
    const transport = receiver.transport(endpoint.port, 1400);
    var previous_port: u16 = 0;
    // Repeat peer 0 from a new bind while the receiver remains attached.
    // This exercises endpoint roaming without a fixed receive-source mapping.
    for ([_]usize{ 0, 1, 0 }) |index| {
        const peer = &peers[index];
        peer.allocator = std.testing.allocator;
        const peer_socket = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })).?;
        const new_port = (try peer_socket.linkDescriptor().localAddress()).port;
        if (index == 0) {
            try std.testing.expect(new_port != previous_port);
            previous_port = new_port;
        }
        peer.replaceLink(peer_socket.linkDescriptor());
        const port = (try peer_socket.linkDescriptor().localAddress()).port;
        const peer_transport = peer.transport(port, 1400);
        const data = [_]u8{ @intCast(index), 42 };
        var completion: Completion = .{};
        const outgoing = [_]c.wg_packet{.{ .data = &data, .size = data.len }};
        try std.testing.expectEqual(c.WG_IO_OK, peer_transport.link.write.?(peer_transport.context, &outgoing, 1, &endpoint, completion.token()));
        try std.testing.expectEqual(c.WG_IO_OK, completion.status);
        try std.testing.expectEqual(@as(usize, 1), completion.calls);
        var bytes: [32]u8 = undefined;
        var incoming = [_]c.wg_read_packet{.{ .data = &bytes, .capacity = bytes.len }};
        for (0..20) |_| {
            completion = .{};
            try std.testing.expectEqual(c.WG_IO_OK, transport.link.read.?(transport.context, &incoming, 1, completion.token()));
            if (completion.count != 0) break;
        }
        try std.testing.expectEqual(@as(u32, 1), completion.count);
        try std.testing.expectEqual(port, incoming[0].source.port);
        try std.testing.expectEqual(@as(u8, 4), incoming[0].source.family);
        try std.testing.expectEqualSlices(u8, &data, bytes[0..incoming[0].size]);
        completion = .{};
        try std.testing.expectEqual(c.WG_IO_OK, transport.link.write.?(transport.context, &outgoing, 1, &incoming[0].source, completion.token()));
        try std.testing.expectEqual(c.WG_IO_OK, completion.status);
        for (0..20) |_| {
            completion = .{};
            try std.testing.expectEqual(c.WG_IO_OK, peer_transport.link.read.?(peer_transport.context, &incoming, 1, completion.token()));
            if (completion.count != 0) break;
        }
        try std.testing.expectEqual(@as(u32, 1), completion.count);
        try std.testing.expectEqual(endpoint.port, incoming[0].source.port);
        try std.testing.expectEqualSlices(u8, &data, bytes[0..incoming[0].size]);
    }
    // Waiting reads bypass allocation; queued packets free a payload and node.
    try std.testing.expect(clearing.frees <= 6 and clearing.frees % 2 == 0);
    receiver.quiesce();
    var completion: Completion = .{};
    var bytes: [32]u8 = undefined;
    var incoming = [_]c.wg_read_packet{.{ .data = &bytes, .capacity = bytes.len }};
    try std.testing.expectEqual(c.WG_IO_OK, transport.link.read.?(transport.context, &incoming, 1, completion.token()));
    try std.testing.expectEqual(c.WG_IO_CLOSED, completion.status);
    try std.testing.expectEqual(@as(usize, 1), completion.calls);
}

const ReadRequest = struct {
    passive: *bridge.PassiveIO,
    side: source.net.Side,
    packets: [*c]c.wg_read_packet,
    result: *Completion,
    status: i32 = 99,
    fn run(self: *ReadRequest) void {
        const transport = self.passive.transport(51820, 1400);
        const read = if (self.side == .link) transport.link.read else transport.tun.read;
        self.status = read.?(transport.context, self.packets, 1, self.result.token());
    }
};

const FailureRecorder = struct {
    calls: usize = 0,
    fn report(raw: *anyopaque) void {
        const self: *FailureRecorder = @ptrCast(@alignCast(raw));
        self.calls += 1;
    }
};

test "WireGuard passive initial transport allocation failure stays closed and reports once" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    var passive = try bridge.PassiveIO.init(Completion.finish);
    defer passive.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    passive.allocator = failing.allocator();
    var failure = FailureRecorder{};
    passive.failure = .{ .ctx = &failure, .report = FailureRecorder.report };
    const socket = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })).?;
    passive.replaceLink(socket.linkDescriptor());
    try std.testing.expect(!passive.hasIO());
    try std.testing.expectEqual(@as(usize, 1), failure.calls);
    passive.activate();
    var bytes: [32]u8 = undefined;
    var packets = [_]c.wg_read_packet{.{ .data = &bytes, .capacity = bytes.len }};
    var completion = Completion{};
    const callbacks = passive.transport(51820, 1400);
    try std.testing.expectEqual(c.WG_IO_OK, callbacks.link.read.?(callbacks.context, &packets, 1, completion.token()));
    try std.testing.expectEqual(c.WG_IO_CLOSED, completion.status);
    try std.testing.expectEqual(@as(usize, 1), failure.calls);
    // Replacing the failed link is an explicit recovery, unlike activation.
    passive.allocator = std.testing.allocator;
    const replacement = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })).?;
    passive.replaceLink(replacement.linkDescriptor());
    try std.testing.expect(passive.hasIO());
    try std.testing.expect(!passive.closed);
}

fn waitForPendingReads(passive: *bridge.PassiveIO, side: source.net.Side, count: usize) !void {
    for (0..1000) |_| {
        if (bridge.PassiveIO.testing.pendingReads(passive, side) == count) return;
        source.core.sleepMs(1);
    }
    return error.TestUnexpectedResult;
}

const PosixPacketIO = struct {
    writes: usize = 0,
    cleanups: usize = 0,
    block_after: ?usize = null,
    short_write: bool = false,
    read_error: bool = false,
    payload: ?[]const u8 = null,
    delivered: bool = false,

    fn read(raw: *anyopaque, buffer: []u8) io.Error!?usize {
        const self: *PosixPacketIO = @ptrCast(@alignCast(raw));
        if (self.read_error) return error.LibcFailure;
        if (!self.delivered) if (self.payload) |payload| {
            @memcpy(buffer[0..payload.len], payload);
            self.delivered = true;
            return payload.len;
        };
        return error.WouldBlock;
    }
    fn write(raw: *anyopaque, data: []const u8, _: usize) io.Error!usize {
        const self: *PosixPacketIO = @ptrCast(@alignCast(raw));
        if (self.short_write) return 0;
        if (self.writes == self.block_after) return error.Backpressure;
        self.writes += 1;
        return data.len;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *PosixPacketIO = @ptrCast(@alignCast(raw));
        self.cleanups += 1;
    }
    fn lastError(_: *anyopaque) c_int {
        return 0;
    }
    fn descriptor(self: *PosixPacketIO) io.TunDescriptor {
        return .{ .fd = -1, .io = .{ .mock = .{ .ptr = self, .vtable = &.{
            .read = read,
            .write = write,
            .cleanup = cleanup,
            .last_error_code = lastError,
        } } } };
    }
};

test "POSIX passive initial TUN commit fills a waiting read without packet allocations" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var passive = try bridge.PassiveIO.init(Completion.finish);
    defer passive.deinit();
    // Only the two descriptor adapters may allocate; input must bypass queues.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    passive.allocator = failing.allocator();
    var link = PosixPacketIO{};
    var tun = PosixPacketIO{ .payload = "ip packet" };
    passive.replaceLink(link.descriptor());
    var bytes: [32]u8 = undefined;
    var packet = [_]c.wg_read_packet{.{ .data = &bytes, .capacity = bytes.len }};
    var result = Completion{};
    var request = ReadRequest{ .passive = &passive, .side = .tun, .packets = &packet, .result = &result };
    var thread: ?std.Thread = try std.Thread.spawn(.{}, ReadRequest.run, .{&request});
    defer if (thread) |value| {
        passive.quiesce();
        value.join();
    };
    try waitForPendingReads(&passive, .tun, 1);
    passive.replaceTun(tun.descriptor());
    thread.?.join();
    thread = null;
    try std.testing.expectEqual(c.WG_IO_OK, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqualStrings("ip packet", bytes[0..packet[0].size]);
    try std.testing.expect(!failing.has_induced_failure);
    passive.release();
    try std.testing.expectEqual(@as(usize, 1), tun.cleanups);
    try std.testing.expectEqual(@as(usize, 1), link.cleanups);
}

test "POSIX callback adapter releases an incoming descriptor on allocation failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var tun = PosixPacketIO{};
    try std.testing.expectError(error.OutOfMemory, source.net.CallbackTransport.create(failing.allocator(), .{ .tun = tun.descriptor() }));
    try std.testing.expectEqual(@as(usize, 1), tun.cleanups);
}

test "POSIX passive write retries preserve the completed prefix and release readers" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var passive = try bridge.PassiveIO.init(Completion.finish);
    passive.allocator = std.testing.allocator;
    defer passive.deinit();
    var link = PosixPacketIO{};
    var tun = PosixPacketIO{ .block_after = 1 };
    passive.replaceLink(link.descriptor());
    passive.replaceTun(tun.descriptor());
    const transport = passive.transport(51820, 1400);
    const packets = [_]c.wg_packet{ .{ .data = "one", .size = 3 }, .{ .data = "two", .size = 3 } };
    var result = Completion{};
    try std.testing.expectEqual(c.WG_IO_OK, transport.tun.write.?(transport.context, &packets, packets.len, result.token()));
    try std.testing.expectEqual(c.WG_IO_AGAIN, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    tun.block_after = null;
    try std.testing.expectEqual(c.WG_IO_OK, transport.tun.write.?(transport.context, packets[1..].ptr, 1, result.token()));
    try std.testing.expectEqual(c.WG_IO_OK, result.status);
    try std.testing.expectEqual(@as(usize, 2), tun.writes);
    passive.release();
    try std.testing.expectEqual(@as(usize, 1), tun.cleanups);
    try std.testing.expectEqual(@as(usize, 1), link.cleanups);
}

test "POSIX passive receive and short write failures report once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |read_error| {
        var passive = try bridge.PassiveIO.init(Completion.finish);
        passive.allocator = std.testing.allocator;
        defer passive.deinit();
        var failure = FailureRecorder{};
        passive.failure = .{ .ctx = &failure, .report = FailureRecorder.report };
        var link = PosixPacketIO{};
        var tun = PosixPacketIO{ .read_error = read_error, .short_write = !read_error };
        passive.replaceLink(link.descriptor());
        passive.replaceTun(tun.descriptor());
        const transport = passive.transport(51820, 1400);
        var result = Completion{};
        if (read_error) {
            var bytes: [32]u8 = undefined;
            var packet = [_]c.wg_read_packet{.{ .data = &bytes, .capacity = bytes.len }};
            for (0..20) |_| {
                try std.testing.expectEqual(c.WG_IO_OK, transport.tun.read.?(transport.context, &packet, 1, result.token()));
                if (result.status == c.WG_IO_CLOSED) break;
            }
            try std.testing.expectEqual(c.WG_IO_CLOSED, result.status);
        } else {
            const packets = [_]c.wg_packet{.{ .data = "bad", .size = 3 }};
            try std.testing.expectEqual(c.WG_IO_OK, transport.tun.write.?(transport.context, &packets, 1, result.token()));
            try std.testing.expectEqual(c.WG_IO_INVALID, result.status);
        }
        passive.release(); // Joins receive callbacks before inspecting their report.
        try std.testing.expectEqual(@as(usize, 1), failure.calls);
        try std.testing.expectEqual(@as(usize, 1), link.cleanups);
        try std.testing.expectEqual(@as(usize, 1), tun.cleanups);
    }
}

test "WireGuard passive waiting reads receive without packet allocations" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    for ([_]source.net.Side{ .link, .tun }) |side| {
        var passive = try bridge.PassiveIO.init(Completion.finish);
        defer passive.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        passive.allocator = failing.allocator();
        bridge.PassiveIO.testing.attach(&passive, side);
        var buffers: [2][32]u8 = undefined;
        var packets: [2]c.wg_read_packet = undefined;
        var results: [2]Completion = .{ .{}, .{} };
        var requests: [2]ReadRequest = undefined;
        var threads: [2]?std.Thread = .{ null, null };
        defer {
            passive.quiesce();
            for (threads) |thread| if (thread) |value| value.join();
        }
        for (0..2) |i| {
            packets[i] = .{ .data = &buffers[i], .capacity = buffers[i].len };
            requests[i] = .{ .passive = &passive, .side = side, .packets = &packets[i], .result = &results[i] };
            threads[i] = try std.Thread.spawn(.{}, ReadRequest.run, .{&requests[i]});
            try waitForPendingReads(&passive, side, i + 1);
        }
        var address = std.mem.zeroes(io.SocketAddress);
        address.family = 6;
        address.address[15] = 1;
        address.scope_id = 7;
        address.port = 51820;
        // Each callback must fill the oldest pending read, including empty UDP.
        try std.testing.expect(bridge.PassiveIO.testing.receive(&passive, side, "direct", if (side == .link) &address else null, 0));
        try std.testing.expect(bridge.PassiveIO.testing.receive(&passive, side, "", if (side == .link) &address else null, 0));
        for (&threads) |*thread| {
            thread.*.?.join();
            thread.* = null;
        }
        for (results) |result| {
            try std.testing.expectEqual(@as(usize, 1), result.calls);
            try std.testing.expectEqual(@as(u32, 1), result.count);
            try std.testing.expectEqual(c.WG_IO_OK, result.status);
        }
        try std.testing.expectEqualStrings("direct", buffers[0][0..packets[0].size]);
        try std.testing.expectEqual(@as(u32, 0), packets[1].size);
        if (side == .link) {
            try std.testing.expectEqual(address.port, packets[0].source.port);
            try std.testing.expectEqual(address.scope_id, packets[0].source.scope_id);
            try std.testing.expectEqualSlices(u8, &address.address, &packets[0].source.address);
        }
        try std.testing.expectEqual(@as(usize, 0), bridge.PassiveIO.testing.pendingReads(&passive, side));
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "WireGuard passive queued reads preserve batching and discard oversized packets" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    var clearing = ClearingAllocator{ .arena = .init(std.testing.allocator) };
    defer clearing.arena.deinit();
    var passive = try bridge.PassiveIO.init(Completion.finish);
    passive.allocator = clearing.allocator();
    defer passive.deinit();
    bridge.PassiveIO.testing.attach(&passive, .tun);
    for ([_][]const u8{ "one", "two", "oversized" }) |bytes|
        try std.testing.expect(bridge.PassiveIO.testing.receive(&passive, .tun, bytes, null, 0));
    var buffers: [3][4]u8 = undefined;
    var packets: [3]c.wg_read_packet = undefined;
    for (&packets, &buffers) |*packet, *buffer| packet.* = .{ .data = buffer, .capacity = buffer.len };
    var result = Completion{};
    const transport = passive.transport(51820, 1400);
    try std.testing.expectEqual(c.WG_IO_OK, transport.tun.read.?(transport.context, &packets, packets.len, result.token()));
    try std.testing.expectEqual(c.WG_IO_OK, result.status);
    try std.testing.expectEqual(@as(u32, 2), result.count);
    try std.testing.expectEqualStrings("one", buffers[0][0..packets[0].size]);
    try std.testing.expectEqualStrings("two", buffers[1][0..packets[1].size]);
    // Payloads must be freed before their nodes, including the discarded packet.
    try std.testing.expectEqual(@as(usize, 6), clearing.frees);
}

test "WireGuard passive pending buffers are unregistered on timeout cancellation detach and failure" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    const Scenario = enum { timeout, cancel, detach, failure, oversized };
    for (std.enums.values(Scenario)) |scenario| {
        var passive = try bridge.PassiveIO.init(Completion.finish);
        passive.allocator = std.testing.allocator;
        defer passive.deinit();
        var failure = FailureRecorder{};
        passive.failure = .{ .ctx = &failure, .report = FailureRecorder.report };
        bridge.PassiveIO.testing.attach(&passive, .link);
        var bytes = [_]u8{42} ** 4;
        var packet = [_]c.wg_read_packet{.{ .data = &bytes, .capacity = bytes.len }};
        var result = Completion{};
        var request = ReadRequest{ .passive = &passive, .side = .link, .packets = &packet, .result = &result };
        var thread: ?std.Thread = try std.Thread.spawn(.{}, ReadRequest.run, .{&request});
        defer if (thread) |value| {
            passive.quiesce();
            value.join();
        };
        try waitForPendingReads(&passive, .link, 1);
        var address = std.mem.zeroes(io.SocketAddress);
        address.family = 4;
        switch (scenario) {
            .timeout => {},
            .cancel => passive.quiesce(),
            .detach => passive.releaseLink(),
            .failure => try std.testing.expect(!bridge.PassiveIO.testing.receive(&passive, .link, "", null, -1)),
            .oversized => try std.testing.expect(bridge.PassiveIO.testing.receive(&passive, .link, "too large", &address, 0)),
        }
        thread.?.join();
        thread = null;
        try std.testing.expectEqual(@as(usize, 1), result.calls);
        try std.testing.expectEqual(@as(u32, 0), result.count);
        try std.testing.expectEqual(if (scenario == .cancel or scenario == .failure) c.WG_IO_CLOSED else c.WG_IO_AGAIN, result.status);
        try std.testing.expectEqual(@as(usize, if (scenario == .failure) 1 else 0), failure.calls);
        try std.testing.expectEqual(@as(usize, 0), bridge.PassiveIO.testing.pendingReads(&passive, .link));
        // A callback after completion must queue instead of touching old storage.
        bridge.PassiveIO.testing.attach(&passive, .link);
        try std.testing.expect(bridge.PassiveIO.testing.receive(&passive, .link, "late", &address, 0));
        try std.testing.expectEqualSlices(u8, &([_]u8{42} ** 4), &bytes);
        try std.testing.expectEqual(@as(usize, 1), passive.sides[0].count);
    }
}
