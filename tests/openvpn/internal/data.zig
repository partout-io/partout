// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const core = source.core;
const crypto_c = source.ffi.crypto;
const data = source.openvpn_internal.data;
const helpers = source.openvpn_internal.helpers;
const api = core.api;

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

test "DataPath mock round trips every compression framing in AEAD and HMAC modes" {
    const framings = [_]api.OpenVPNCompressionFraming{
        .disabled,
        .compLZO,
        .compress,
        .compressV2,
    };
    for (framings) |framing| {
        try expectMockDataPathRoundTrip(framing, false);
        try expectMockDataPathRoundTrip(framing, true);
    }
}

test "DataPath compress-v2 mock preserves framing magic payloads" {
    const allocator = std.testing.allocator;
    const data_path = try data.testing.createMockDataPathWithFraming(
        allocator,
        1,
        .compressV2,
        false,
    );
    defer data_path.destroy();
    const payloads = [_][]const u8{
        &.{0xfb},
        &.{0x66},
        &.{0x50},
        &.{0x00},
    };
    const encrypted = try data_path.encryptPackets(allocator, &payloads, 2);
    defer core.util.freeSliceOfStrings(allocator, encrypted);
    var decrypted = try data_path.decryptPackets(allocator, encrypted);
    defer decrypted.deinit(allocator);

    try std.testing.expectEqual(@as(usize, payloads.len), decrypted.packets.len);
    for (payloads, decrypted.packets) |expected, actual| {
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

test "DataLink declarations are semantically analyzed" {
    std.testing.refAllDecls(data.DataLink);
}

test "DataPath preserves native failure categories" {
    const openvpn_c = helpers.openvpn_c;
    const errorFromNative = data.testing.errorFromNative;

    try std.testing.expectEqual(error.DataPathFailure, errorFromNative(.{
        .dp_code = openvpn_c.OpenVPNDataPathErrorNone,
        .crypto_code = crypto_c.PPCryptoErrorNone,
    }));
    try std.testing.expectEqual(error.PeerIdMismatch, errorFromNative(.{
        .dp_code = openvpn_c.OpenVPNDataPathErrorPeerIdMismatch,
        .crypto_code = crypto_c.PPCryptoErrorNone,
    }));
    try std.testing.expectEqual(error.CompressionMismatch, errorFromNative(.{
        .dp_code = openvpn_c.OpenVPNDataPathErrorCompression,
        .crypto_code = crypto_c.PPCryptoErrorNone,
    }));
    try std.testing.expectEqual(error.CryptoEncryption, errorFromNative(.{
        .dp_code = openvpn_c.OpenVPNDataPathErrorCrypto,
        .crypto_code = crypto_c.PPCryptoErrorEncryption,
    }));
    try std.testing.expectEqual(error.CryptoHMAC, errorFromNative(.{
        .dp_code = openvpn_c.OpenVPNDataPathErrorCrypto,
        .crypto_code = crypto_c.PPCryptoErrorHMAC,
    }));
}

fn expectMockDataPathRoundTrip(
    framing: api.OpenVPNCompressionFraming,
    authenticated: bool,
) !void {
    const allocator = std.testing.allocator;
    const data_path = try data.testing.createMockDataPathWithFraming(
        allocator,
        1,
        framing,
        authenticated,
    );
    defer data_path.destroy();
    const payloads = [_][]const u8{
        &.{0x11},
        &.{ 0x22, 0x22 },
        &.{ 0x33, 0x33, 0x33 },
    };
    const encrypted = try data_path.encryptPackets(allocator, &payloads, 2);
    defer core.util.freeSliceOfStrings(allocator, encrypted);
    var decrypted = try data_path.decryptPackets(allocator, encrypted);
    defer decrypted.deinit(allocator);

    try std.testing.expectEqual(@as(usize, payloads.len), decrypted.packets.len);
    for (payloads, decrypted.packets) |expected, actual| {
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}
