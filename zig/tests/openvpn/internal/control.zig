// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const core = source.core;
const internal = source.openvpn_internal;
const ControlPacket = internal.packet.ControlPacket;
const PacketCode = internal.packet.PacketCode;
const Serializer = internal.serialization.Serializer;
const TestControlChannel = internal.control.ControlChannel(Serializer);

test "control channel fragments payload and retains opcode" {
    const channel = try TestControlChannel.create(
        std.testing.allocator,
        .system(),
        .{ .plain = .{} },
    );
    defer channel.destroy();
    try channel.reset(true);
    try channel.enqueueOutboundPackets(.controlV1, .controlV1, 0, &.{ 1, 2, 3, 4, 5, 6 }, 4, 4);
    const packets = try channel.writeOutboundPackets(0);
    defer core.util.freeSliceOfStrings(std.testing.allocator, packets);
    try std.testing.expectEqual(@as(usize, 2), packets.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PacketCode.controlV1)), packets[0][0] >> 3);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PacketCode.controlV1)), packets[1][0] >> 3);
}

test "control channel reorders and deduplicates inbound packets" {
    const channel = try TestControlChannel.create(
        std.testing.allocator,
        .system(),
        .{ .plain = .{} },
    );
    defer channel.destroy();
    const sequence1 = [_]u32{ 0, 5, 2, 1, 4, 3 };
    const sequence2 = [_]u32{ 5, 2, 1, 9, 4, 3, 0, 8, 7, 10, 4, 3, 5, 6 };
    const sequence3 = [_]u32{ 5, 2, 11, 1, 2, 9, 4, 5, 5, 3, 8, 0, 6, 8, 2, 7, 10, 4, 3, 5, 6 };
    const sequences = [_][]const u32{ &sequence1, &sequence2, &sequence3 };

    for (sequences, 0..) |sequence, sequence_index| {
        try channel.reset(true);
        const sid = channel.sessionId().?;
        var handled: std.ArrayList(u32) = .empty;
        defer handled.deinit(std.testing.allocator);
        for (sequence) |packet_id| {
            const packet = try ControlPacket.init(.controlV1, 0, sid, packet_id, null, null, null);
            const ready = try channel.enqueueInboundPacket(packet);
            defer std.testing.allocator.free(ready);
            for (ready) |*item| {
                try handled.append(std.testing.allocator, item.packetId());
                item.deinit();
            }
        }
        const expected_count: usize = switch (sequence_index) {
            0 => 6,
            1 => 11,
            2 => 12,
            else => unreachable,
        };
        try std.testing.expectEqual(expected_count, handled.items.len);
        for (handled.items, 0..) |packet_id, expected| {
            try std.testing.expectEqual(@as(u32, @intCast(expected)), packet_id);
        }
    }
}

test "control channel suppresses retransmission until ACK" {
    const channel = try TestControlChannel.create(
        std.testing.allocator,
        .system(),
        .{ .plain = .{} },
    );
    defer channel.destroy();
    try channel.reset(true);
    try channel.enqueueOutboundPackets(.controlV1, .controlV1, 0, "hello", 64, 64);

    const first_write = try channel.writeOutboundPackets(60_000);
    defer core.util.freeSliceOfStrings(std.testing.allocator, first_write);
    try std.testing.expectEqual(@as(usize, 1), first_write.len);
    try std.testing.expect(channel.pending_acks.count() > 0);

    const suppressed = try channel.writeOutboundPackets(60_000);
    defer core.util.freeSliceOfStrings(std.testing.allocator, suppressed);
    try std.testing.expectEqual(@as(usize, 0), suppressed.len);

    const packet_ids = [_]u32{0};
    const raw_ack = try channel.writeAcks(0, &packet_ids, channel.sessionId().?);
    defer std.testing.allocator.free(raw_ack);
    var ack = try channel.readInboundPacket(raw_ack, 0);
    defer ack.deinit();
    try std.testing.expectEqual(@as(usize, 0), channel.pending_acks.count());
    try std.testing.expectEqual(@as(usize, 0), channel.outbound_queue.items.len);
    try std.testing.expectEqual(@as(usize, 1), channel.sent_dates_ms.count());
}

test "tls-auth channels round trip fragmented payloads" {
    try expectProtectedRoundTrip(.auth, 7);
}

test "tls-crypt-v2 carries the wrapped key only on leading WKC packets" {
    const allocator = std.testing.allocator;
    var key_bytes: [256]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| byte.* = @truncate(index);
    var key = try api.SecureData.initBytesAlloc(allocator, &key_bytes);
    defer key.deinit(allocator);
    const wrapped_bytes = [_]u8{ 0xca, 0xfe, 0xba, 0xbe };
    var wrapped = try api.SecureData.initBytesAlloc(allocator, &wrapped_bytes);
    defer wrapped.deinit(allocator);
    const configuration = api.OpenVPNConfiguration{ .tls_wrap = .{
        .strategy = .cryptV2,
        .key = .{ .data = key, .dir = .client },
        .wrapped_key = wrapped,
    } };
    const serializer = try Serializer.forConfiguration(
        allocator,
        .mock,
        &configuration,
    );
    const channel = try TestControlChannel.create(allocator, .system(), serializer);
    defer channel.destroy();
    try channel.reset(true);
    try channel.enqueueOutboundPackets(
        .controlWkcV1,
        .controlV1,
        0,
        &.{ 1, 2, 3, 4, 5, 6 },
        1,
        4,
    );

    const packets = try channel.writeOutboundPackets(0);
    defer core.util.freeSliceOfStrings(allocator, packets);
    try std.testing.expectEqual(@as(usize, 3), packets.len);
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(PacketCode.controlWkcV1)),
        packets[0][0] >> 3,
    );
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(PacketCode.controlV1)),
        packets[1][0] >> 3,
    );
    try std.testing.expect(std.mem.endsWith(u8, packets[0], &wrapped_bytes));
    try std.testing.expect(!std.mem.endsWith(u8, packets[1], &wrapped_bytes));
    try std.testing.expect(!std.mem.endsWith(u8, packets[2], &wrapped_bytes));
}

test "control channel rejects non-positive fragmentation budgets" {
    const channel = try TestControlChannel.create(
        std.testing.allocator,
        .system(),
        .{ .plain = .{} },
    );
    defer channel.destroy();
    try channel.reset(true);
    try std.testing.expectError(
        error.ControlChannelFailure,
        channel.enqueueOutboundPackets(
            .controlWkcV1,
            .controlV1,
            0,
            &.{1},
            0,
            4,
        ),
    );
}

fn expectProtectedRoundTrip(
    strategy: api.OpenVPNTLSWrapStrategy,
    payload_byte: u8,
) !void {
    const allocator = std.testing.allocator;
    var key_bytes: [256]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| byte.* = @truncate(index);
    var key = try api.SecureData.initBytesAlloc(allocator, &key_bytes);
    defer key.deinit(allocator);

    const client_configuration = api.OpenVPNConfiguration{
        .digest = .sha256,
        .tls_wrap = .{
            .strategy = strategy,
            .key = .{ .data = key, .dir = .client },
        },
    };
    const server_configuration = api.OpenVPNConfiguration{
        .digest = .sha256,
        .tls_wrap = .{
            .strategy = strategy,
            .key = .{ .data = key, .dir = .server },
        },
    };
    const client_serializer = try Serializer.forConfiguration(
        allocator,
        .mock,
        &client_configuration,
    );
    const client = try TestControlChannel.create(
        allocator,
        .system(),
        client_serializer,
    );
    defer client.destroy();
    const server_serializer = try Serializer.forConfiguration(
        allocator,
        .mock,
        &server_configuration,
    );
    const server = try TestControlChannel.create(
        allocator,
        .system(),
        server_serializer,
    );
    defer server.destroy();
    try client.reset(true);
    try server.reset(true);
    const payload = [_]u8{payload_byte} ** 6;
    try client.enqueueOutboundPackets(
        .controlV1,
        .controlV1,
        0,
        &payload,
        4,
        4,
    );

    const raw_packets = try client.writeOutboundPackets(0);
    defer core.util.freeSliceOfStrings(allocator, raw_packets);
    try std.testing.expectEqual(@as(usize, 2), raw_packets.len);
    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(allocator);
    for (raw_packets) |raw| {
        var decoded = try server.readInboundPacket(raw, 0);
        defer decoded.deinit();
        try std.testing.expectEqual(PacketCode.controlV1, decoded.code);
        if (decoded.payload()) |part| try reassembled.appendSlice(allocator, part);
    }
    try std.testing.expectEqualSlices(u8, &payload, reassembled.items);
}
