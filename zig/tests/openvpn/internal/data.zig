// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const core = source.core;
const data = source.openvpn_internal.data;

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

test "DataLink declarations are semantically analyzed" {
    std.testing.refAllDecls(data.DataLink);
}

test "DataLink preserves only reportable inbound failure categories" {
    try std.testing.expectEqual(error.CryptoFailure, data.testing.mapInboundError(error.CryptoFailure));
    try std.testing.expectEqual(error.CompressionMismatch, data.testing.mapInboundError(error.CompressionMismatch));
    try std.testing.expectEqual(error.Reconnect, data.testing.mapInboundError(error.OutOfMemory));
}
