// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const c = @import("c.zig").api;
const CControlPacket = @import("c_control_packet.zig").CControlPacket;
const CPacketCode = @import("c_packet_code.zig").CPacketCode;
const ControlChannelSerializer = @import("control_channel_serializer.zig").ControlChannelSerializer;
const errors = @import("errors.zig");

pub const PlainSerializer = struct {
    pub const ParseError = errors.PlainSerializerError;

    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!ControlChannelSerializer {
        const self = try allocator.create(PlainSerializer);
        self.* = .{};
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(_: *PlainSerializer) void {}

    pub fn serialize(
        _: *PlainSerializer,
        allocator: std.mem.Allocator,
        packet: *const CControlPacket,
    ) std.mem.Allocator.Error![]u8 {
        return packet.serializedAlloc(allocator);
    }

    pub fn deserialize(
        _: *PlainSerializer,
        _: std.mem.Allocator,
        data: []const u8,
        start: usize,
        optional_end: ?usize,
    ) (ParseError || CControlPacket.InitError)!CControlPacket {
        const end = optional_end orelse data.len;
        if (start > end or end > data.len) return error.InvalidRange;
        var offset = start;

        if (end - offset < c.OpenVPNPacketOpcodeLength) return error.MissingOpcode;
        const code = CPacketCode.fromRaw(data[offset] >> 3) orelse return error.UnknownCode;
        const key = data[offset] & 0b111;
        offset += c.OpenVPNPacketOpcodeLength;

        if (end - offset < c.OpenVPNPacketSessionIdLength) return error.MissingSessionId;
        const session_id = data[offset .. offset + c.OpenVPNPacketSessionIdLength];
        offset += c.OpenVPNPacketSessionIdLength;

        if (end - offset < c.OpenVPNPacketAckLengthLength) return error.MissingAckSize;
        const ack_count: usize = data[offset];
        offset += c.OpenVPNPacketAckLengthLength;

        var ack_storage: [std.math.maxInt(u8)]u32 = undefined;
        var ack_ids: ?[]const u32 = null;
        var remote_session_id: ?[]const u8 = null;
        if (ack_count > 0) {
            const ack_bytes = ack_count * c.OpenVPNPacketIdLength;
            if (end - offset < ack_bytes) return error.MissingAcks;
            for (ack_storage[0..ack_count]) |*ack_id| {
                ack_id.* = std.mem.readInt(u32, data[offset..][0..4], .big);
                offset += c.OpenVPNPacketIdLength;
            }
            ack_ids = ack_storage[0..ack_count];

            if (end - offset < c.OpenVPNPacketSessionIdLength) return error.MissingRemoteSessionId;
            remote_session_id = data[offset .. offset + c.OpenVPNPacketSessionIdLength];
            offset += c.OpenVPNPacketSessionIdLength;
        }

        if (code == .ackV1) {
            const ids = ack_ids orelse return error.AckPacketWithoutIds;
            const remote = remote_session_id orelse return error.AckPacketWithoutRemoteSessionId;
            return CControlPacket.initAck(key, session_id, ids, remote);
        }

        if (end - offset < c.OpenVPNPacketIdLength) return error.MissingPacketId;
        const packet_id = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += c.OpenVPNPacketIdLength;
        const payload: ?[]const u8 = if (offset < end) data[offset..end] else null;
        return CControlPacket.init(code, key, session_id, packet_id, payload, ack_ids, remote_session_id);
    }

    fn erasedReset(raw: *anyopaque) void {
        reset(@ptrCast(@alignCast(raw)));
    }

    fn erasedSerialize(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        packet: *const CControlPacket,
    ) anyerror![]u8 {
        return serialize(@ptrCast(@alignCast(raw)), allocator, packet);
    }

    fn erasedDeserialize(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        data: []const u8,
        start: usize,
        end: ?usize,
    ) anyerror!CControlPacket {
        return deserialize(@ptrCast(@alignCast(raw)), allocator, data, start, end);
    }

    fn erasedDestroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*PlainSerializer, @ptrCast(@alignCast(raw))));
    }

    const vtable: ControlChannelSerializer.VTable = .{
        .reset = erasedReset,
        .serialize = erasedSerialize,
        .deserialize = erasedDeserialize,
        .destroy = erasedDestroy,
    };
};

test "plain serializer round trips control and ACK packets" {
    var interface = try PlainSerializer.create(std.testing.allocator);
    defer interface.deinit(std.testing.allocator);
    const sid = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const payload = [_]u8{ 9, 10, 11 };
    var original = try CControlPacket.init(.controlV1, 3, &sid, 42, &payload, null, null);
    defer original.deinit();
    const raw = try interface.serialize(std.testing.allocator, &original);
    defer std.testing.allocator.free(raw);
    var decoded = try interface.deserialize(std.testing.allocator, raw, 0, null);
    defer decoded.deinit();
    try std.testing.expectEqual(CPacketCode.controlV1, decoded.code);
    try std.testing.expectEqual(@as(u32, 42), decoded.packetId());
    try std.testing.expectEqualSlices(u8, &payload, decoded.payload().?);
}

test "plain serializer rejects truncated frames" {
    var serializer: PlainSerializer = .{};
    try std.testing.expectError(error.MissingSessionId, serializer.deserialize(std.testing.allocator, &.{0x20}, 0, null));
}
