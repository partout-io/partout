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

test "DataLink submits encrypted packets once and propagates writer rejection" {
    const Probe = struct {
        channel: *data.DataChannel,
        destination: source.net.SocketAddress,
        writes: usize = 0,
        outbound_bytes: usize = 0,
        rejection: ?source.net.SubmissionError = null,

        fn channelForKey(raw: ?*anyopaque, key: u8) ?*data.DataChannel {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return if (key == self.channel.key) self.channel else null;
        }

        fn write(raw: ?*anyopaque, packets: source.net.Packets, side: source.net.Side, destination: ?source.net.SocketAddress) (source.net.SubmissionError || error{MissingDestination})!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.debug.assert(side == .link);
            std.debug.assert(std.meta.eql(self.destination, destination.?));
            std.debug.assert(packets.len == 1 and packets[0].len > 0);
            self.writes += 1;
            if (self.rejection) |err| return err;
        }

        fn reportOutbound(raw: ?*anyopaque, count: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.outbound_bytes += count;
        }

        fn reportInbound(_: ?*anyopaque, _: usize) void {}
    };
    const allocator = std.testing.allocator;
    const path = try data.testing.createMockDataPath(allocator, 1);
    const channel = data.DataChannel.create(allocator, 2, path) catch |err| {
        path.destroy();
        return err;
    };
    defer channel.destroy();
    const processor = try source.openvpn_internal.processing.LinkProcessor.create(allocator, null, false);
    defer processor.destroy();
    const endpoint = try source.net.SocketEndpoint.init(.{ .address = "192.0.2.1", .proto = .init(.udp, 1194) });
    var probe = Probe{ .channel = channel, .destination = endpoint.address };
    var link = data.DataLink.init(allocator, endpoint, processor, &probe, .{
        .write_packets = Probe.write,
        .data_channel = Probe.channelForKey,
        .report_inbound_data_count = Probe.reportInbound,
        .report_outbound_data_count = Probe.reportOutbound,
    });
    const pair = data.DataLinkPair{ .link = &link, .key = channel.key };
    try pair.send(&.{"payload"});
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
    try std.testing.expect(probe.outbound_bytes > 0);

    for ([_]source.net.SubmissionError{ error.LooperUnavailable, error.OutOfMemory }) |err| {
        probe.rejection = err;
        const before = probe.writes;
        try std.testing.expectError(err, pair.send(&.{"payload"}));
        try std.testing.expectEqual(before + 1, probe.writes);
    }
}
