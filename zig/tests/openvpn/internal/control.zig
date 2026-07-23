// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

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
    try channel.reset(true);
    const sid = channel.sessionId().?;
    const sequence = [_]u32{ 2, 0, 1, 1 };
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
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, handled.items);
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
