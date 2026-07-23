// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const core = source.core;
const data = source.openvpn_internal.data;
const errors = source.openvpn_internal.errors;

test "DataPath mock round-trips compound and bulk packets" {
    const allocator = std.testing.allocator;
    const peer_id: u32 = 0x01;
    const key: u8 = 0x02;
    const packet_id: u32 = 0x1020;
    const payload = [_]u8{ 0x11, 0x22, 0x33, 0x44 };

    const data_path = try data.testing.createMockDataPath(allocator, peer_id);
    defer data_path.destroy();

    const compound = try data_path.assembleAndEncrypt(
        allocator,
        &payload,
        key,
        packet_id,
    );
    defer allocator.free(compound);
    var compound_result = try data_path.decryptAndParse(allocator, compound);
    defer compound_result.deinit(allocator);
    try std.testing.expectEqual(packet_id, compound_result.packet_id);
    try std.testing.expectEqualSlices(u8, &payload, compound_result.data);

    const packets = [_][]const u8{&payload};
    const encrypted_packets = try data_path.encryptPackets(allocator, &packets, key);
    defer core.util.freeSliceOfStrings(allocator, encrypted_packets);
    var decrypted_packets = try data_path.decryptPackets(allocator, encrypted_packets);
    defer decrypted_packets.deinit(allocator);
    try std.testing.expect(!decrypted_packets.keep_alive);
    try std.testing.expectEqual(@as(usize, 1), decrypted_packets.packets.len);
    try std.testing.expectEqualSlices(u8, &payload, decrypted_packets.packets[0]);
}

test "DataPath clamps TCP MSS before UDP encryption" {
    const allocator = std.testing.allocator;
    const peer_id: u32 = 0x01;
    const key: u8 = 0x02;
    const packet_id: u32 = 0x1020;
    const mss: u16 = 1250;

    // IPv4 + TCP SYN with a 1460-byte MSS option.
    const packet = [_]u8{
        0x45, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x40, 0x00,
        0x40, 0x06, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x01,
        0x0a, 0x00, 0x00, 0x02, 0x30, 0x39, 0x01, 0xbb,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x02, 0xff, 0xff, 0x12, 0x34, 0x00, 0x00,
        0x02, 0x04, 0x05, 0xb4,
    };

    const data_path = try data.testing.createMockDataPathWithMss(
        allocator,
        peer_id,
        mss,
    );
    defer data_path.destroy();

    const encrypted = try data_path.assembleAndEncrypt(
        allocator,
        &packet,
        key,
        packet_id,
    );
    defer allocator.free(encrypted);
    var result = try data_path.decryptAndParse(allocator, encrypted);
    defer result.deinit(allocator);

    try std.testing.expectEqual(packet_id, result.packet_id);
    try std.testing.expectEqual(packet.len, result.data.len);
    try std.testing.expectEqualSlices(u8, packet[0..36], result.data[0..36]);
    try std.testing.expect(!std.mem.eql(u8, packet[36..38], result.data[36..38]));
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0xe2 }, result.data[42..44]);
}

test "DataPath MSS clamp supports IPv6 TCP SYN packets" {
    const allocator = std.testing.allocator;
    const mss: u16 = 1250;

    // IPv6 + TCP SYN with a 1440-byte MSS option.
    const packet = [_]u8{
        0x60, 0x00, 0x00, 0x00, 0x00, 0x18, 0x06, 0x40,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x30, 0x39, 0x01, 0xbb, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x60, 0x02, 0xff, 0xff,
        0x12, 0x34, 0x00, 0x00, 0x02, 0x04, 0x05, 0xa0,
    };

    const data_path = try data.testing.createMockDataPathWithMss(
        allocator,
        0x01,
        mss,
    );
    defer data_path.destroy();

    const encrypted = try data_path.assembleAndEncrypt(
        allocator,
        &packet,
        0x02,
        0x1020,
    );
    defer allocator.free(encrypted);
    var result = try data_path.decryptAndParse(allocator, encrypted);
    defer result.deinit(allocator);

    try std.testing.expectEqual(packet.len, result.data.len);
    try std.testing.expect(!std.mem.eql(u8, packet[56..58], result.data[56..58]));
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0xe2 }, result.data[62..64]);
}

test "DataLink declarations are semantically analyzed" {
    std.testing.refAllDecls(data.DataLink);
}

test "DataLink preserves only reportable inbound failure categories" {
    try std.testing.expectEqual(error.CryptoFailure, errors.sessionError(error.CryptoFailure));
    try std.testing.expectEqual(error.CompressionMismatch, errors.sessionError(error.CompressionMismatch));
    try std.testing.expectEqual(error.Reconnect, errors.sessionError(error.OutOfMemory));
}
