// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const core = source.core;
const processing = source.openvpn_internal.processing;

test "packet directions remain distinct" {
    try std.testing.expect(processing.PacketDirection.outbound != processing.PacketDirection.inbound);
}

test "packet processor applies xormask and xorptrpos byte transforms" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50 };
    const mask = api.SecureData{ .base64 = "AQID" };

    var xormask = try processing.PacketProcessor.init(
        allocator,
        .{ .xormask = .{ .mask = mask } },
    );
    defer xormask.deinit();
    const masked = try xormask.processPacket(allocator, &input, .inbound);
    defer allocator.free(masked);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x11, 0x22, 0x33, 0x41, 0x52 },
        masked,
    );

    var xorptrpos = try processing.PacketProcessor.init(
        allocator,
        .{ .xorptrpos = .{} },
    );
    defer xorptrpos.deinit();
    const positioned = try xorptrpos.processPacket(allocator, &input, .inbound);
    defer allocator.free(positioned);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x11, 0x22, 0x33, 0x44, 0x55 },
        positioned,
    );
}

test "packet processor reverse keeps the opcode byte in place" {
    const allocator = std.testing.allocator;
    var processor = try processing.PacketProcessor.init(
        allocator,
        .{ .reverse = .{} },
    );
    defer processor.deinit();
    const processed = try processor.processPacket(
        allocator,
        &.{ 0x82, 1, 2, 3, 4 },
        .inbound,
    );
    defer allocator.free(processed);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 4, 3, 2, 1 }, processed);
}

test "packet processor obfuscate matches the Swift wire vectors" {
    const allocator = std.testing.allocator;
    const method = api.OpenVPNObfuscationMethod{
        .obfuscate = .{ .mask = .{ .base64 = "Zjc2ZGFiMzA=" } },
    };
    var processor = try processing.PacketProcessor.init(allocator, method);
    defer processor.deinit();
    const plain = try hexBytes(allocator, "832ae7598dfa0378bc19");
    defer allocator.free(plain);
    const obfuscated = try hexBytes(allocator, "e52680106098bc658b15");
    defer allocator.free(obfuscated);

    const outbound = try processor.processPacket(allocator, plain, .outbound);
    defer allocator.free(outbound);
    try std.testing.expectEqualSlices(u8, obfuscated, outbound);

    const inbound = try processor.processPacket(allocator, obfuscated, .inbound);
    defer allocator.free(inbound);
    try std.testing.expectEqualSlices(u8, plain, inbound);
}

test "packet processor methods are reversible" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 0x23, 0x19, 0x72, 0xa4, 0x55, 0x00, 0xfe };
    const mask = api.SecureData{ .base64 = "Zjc2ZGFiMzA=" };
    const methods = [_]?api.OpenVPNObfuscationMethod{
        .{ .xormask = .{ .mask = mask } },
        .{ .xorptrpos = .{} },
        .{ .reverse = .{} },
        .{ .obfuscate = .{ .mask = mask } },
    };

    for (methods) |method| {
        var processor = try processing.PacketProcessor.init(allocator, method);
        defer processor.deinit();
        const outbound = try processor.processPacket(allocator, &payload, .outbound);
        defer allocator.free(outbound);
        const inbound = try processor.processPacket(allocator, outbound, .inbound);
        defer allocator.free(inbound);
        try std.testing.expectEqualSlices(u8, &payload, inbound);
    }
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

test "packet processor frames and parses multiple TCP packets" {
    const allocator = std.testing.allocator;
    var processor = try processing.PacketProcessor.init(allocator, null);
    defer processor.deinit();
    const packet = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    const stream = try processor.streamFromPackets(
        allocator,
        &.{ &packet, &packet, &packet },
    );
    defer allocator.free(stream);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            0, 5, 0x11, 0x22, 0x33, 0x44, 0x55,
            0, 5, 0x11, 0x22, 0x33, 0x44, 0x55,
            0, 5, 0x11, 0x22, 0x33, 0x44, 0x55,
        },
        stream,
    );

    var consumed: usize = 0;
    const parsed = try processor.packetsFromStream(allocator, stream, &consumed);
    defer core.util.freeSliceOfStrings(allocator, parsed);
    try std.testing.expectEqual(stream.len, consumed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    for (parsed) |item| try std.testing.expectEqualSlices(u8, &packet, item);
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

test "LinkProcessor binds UDP processing at creation" {
    const allocator = std.testing.allocator;
    const processor = try processing.LinkProcessor.create(allocator, null, false);
    defer processor.destroy();

    var inbound = try processor.processInbound(&.{ "abc", "de" });
    defer inbound.deinit();
    try std.testing.expectEqual(@as(usize, 2), inbound.packets().len);
    try std.testing.expectEqualStrings("abc", inbound.packets()[0]);
    try std.testing.expectEqualStrings("de", inbound.packets()[1]);

    var outbound = try processor.processOutbound(&.{ "abc", "de" });
    defer outbound.deinit();
    try std.testing.expectEqual(@as(usize, 2), outbound.packets().len);
    try std.testing.expectEqualStrings("abc", outbound.packets()[0]);
    try std.testing.expectEqualStrings("de", outbound.packets()[1]);
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

fn hexBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}
