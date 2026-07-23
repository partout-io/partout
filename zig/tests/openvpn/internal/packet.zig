// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const packet_mod = source.openvpn_internal.packet;

const ControlConstants = source.openvpn_internal.constants.Control;
const ControlPacket = packet_mod.ControlPacket;
const OCCPacket = packet_mod.OCCPacket;
const PacketCode = packet_mod.PacketCode;

test "PIA payload prepends the repeating XOR key" {
    const Fixed = struct {
        fn fill(_: ?*anyopaque, destination: []u8) bool {
            for (destination, 0..) |*byte, index| byte.* = @intCast(index + 1);
            return true;
        }
    };
    const encoded = packet_mod.hardResetPayload(
        std.testing.allocator,
        true,
        "012345",
        "AES-128-CBC",
        "SHA1",
        .{ .fill_fn = Fixed.fill },
    );
    defer std.testing.allocator.free(encoded.?);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, encoded.?[0..3]);
    try std.testing.expectEqual(
        @as(u8, '5' ^ 1),
        encoded.?[3],
    );
}

test "standard hard reset has no payload" {
    try std.testing.expect(packet_mod.hardResetPayload(
        std.testing.allocator,
        false,
        "unused",
        "unused",
        "unused",
        .{},
    ) == null);
}

test "control packet serializes to the Swift wire vector" {
    const session_id = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const payload = [_]u8{ 0x93, 0x27, 0x48, 0x23, 0x87, 0x42, 0x39, 0x75, 0x91, 0x70, 0x48, 0x91 };
    var packet = try ControlPacket.init(.controlV1, 3, &session_id, 0x1456, &payload, null, null);
    defer packet.deinit();

    const serialized = try packet.serializedAlloc(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    const expected = [_]u8{
        0x23, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x00, 0x00, 0x00, 0x14, 0x56, 0x93, 0x27, 0x48, 0x23,
        0x87, 0x42, 0x39, 0x75, 0x91, 0x70, 0x48, 0x91,
    };
    try std.testing.expectEqualSlices(u8, &expected, serialized);
}

test "ACK packet serializes IDs and remote session" {
    const session_id = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const remote_id = [_]u8{ 0xa6, 0x39, 0x32, 0x8c, 0xbf, 0x03, 0x49, 0x0e };
    const ids = [_]u32{ 0xaa, 0xbb };
    var packet = try ControlPacket.initAck(3, &session_id, &ids, &remote_id);
    defer packet.deinit();
    const serialized = try packet.serializedAlloc(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    try std.testing.expectEqual(@as(u8, 0x2b), serialized[0]);
    try std.testing.expectEqual(@as(u8, 2), serialized[9]);
    try std.testing.expectEqualSlices(u8, &remote_id, serialized[18..26]);
}

test "move prevents duplicate C ownership" {
    const id = [_]u8{0} ** ControlConstants.session_id_length;
    var original = try ControlPacket.init(.controlV1, 0, &id, 0, null, null, null);
    var destination = original.move();
    defer destination.deinit();
    try std.testing.expect(original.ptr == null);
}

test "control packet rejects the native ACK sentinel on data opcodes" {
    const id = [_]u8{0} ** ControlConstants.session_id_length;
    try std.testing.expectError(
        error.InvalidPacketId,
        ControlPacket.init(.controlV1, 0, &id, std.math.maxInt(u32), null, null, null),
    );
}

test "packet code wire values match OpenVPN" {
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(PacketCode.controlV1));
    try std.testing.expectEqual(PacketCode.hardResetClientV3, PacketCode.fromRaw(0x0a).?);
    try std.testing.expect(PacketCode.fromRaw(0x7f) == null);
}

test "exit OCC packet matches OpenVPN magic" {
    const raw = OCCPacket.exit.serialized();
    try std.testing.expectEqual(@as(usize, 17), raw.len);
    try std.testing.expectEqual(@as(u8, 0x28), raw[0]);
    try std.testing.expectEqual(@as(u8, 0x06), raw[16]);
}
