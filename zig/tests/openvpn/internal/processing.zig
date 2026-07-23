// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const core = source.core;
const processing = source.openvpn_internal.processing;

test "packet directions remain distinct" {
    try std.testing.expect(processing.PacketDirection.outbound != processing.PacketDirection.inbound);
}

test "packet processor frames and parses a TCP stream" {
    var processor = try processing.PacketProcessor.init(std.testing.allocator, null);
    defer processor.deinit();
    const packet = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    const stream = try processor.streamFromPackets(std.testing.allocator, &.{&packet});
    defer std.testing.allocator.free(stream);
    try std.testing.expectEqualSlices(u8, &.{ 0, 5, 0x11, 0x22, 0x33, 0x44, 0x55 }, stream);

    var consumed: usize = 0;
    const parsed = try processor.packetsFromStream(std.testing.allocator, stream, &consumed);
    defer core.util.freeSliceOfStrings(std.testing.allocator, parsed);
    try std.testing.expectEqual(stream.len, consumed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualSlices(u8, &packet, parsed[0]);
}

test "packet processor retains incomplete TCP frames" {
    var processor = try processing.PacketProcessor.init(std.testing.allocator, null);
    defer processor.deinit();
    var consumed: usize = 99;
    const parsed = try processor.packetsFromStream(std.testing.allocator, &.{ 0, 4, 1, 2 }, &consumed);
    defer core.util.freeSliceOfStrings(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 0), consumed);
    try std.testing.expectEqual(@as(usize, 0), parsed.len);
}

test "LinkProcessor declarations are semantically analyzed" {
    std.testing.refAllDecls(processing.LinkProcessor);
}

test "LinkProcessor retains partial TCP frames and returns explicit ownership" {
    const allocator = std.testing.allocator;
    const processor = try processing.LinkProcessor.create(allocator, null, true);
    defer processor.destroy();

    var outbound = try processor.processOutbound(&.{ "abc", "de" });
    defer outbound.deinit();
    try std.testing.expectEqual(@as(usize, 1), outbound.packets().len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 3, 'a', 'b', 'c', 0, 2, 'd', 'e' },
        outbound.packets()[0],
    );

    var partial = try processor.processInbound(&.{outbound.packets()[0][0..4]});
    defer partial.deinit();
    try std.testing.expectEqual(@as(usize, 0), partial.packets().len);

    var completed = try processor.processInbound(&.{outbound.packets()[0][4..]});
    defer completed.deinit();
    try std.testing.expectEqual(@as(usize, 2), completed.packets().len);
    try std.testing.expectEqualStrings("abc", completed.packets()[0]);
    try std.testing.expectEqualStrings("de", completed.packets()[1]);
}
