// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Owning Zig wrapper around the existing `openvpn_ctrl` C entity.

const std = @import("std");

const c_crypto = @import("../../c/exports.zig").crypto;
const c = @import("c.zig").api;
const errors = @import("errors.zig");
const CPacketCode = @import("c_packet_code.zig").CPacketCode;

pub const CControlPacket = struct {
    ptr: ?*c.openvpn_ctrl,
    code: CPacketCode,

    pub const InitError = errors.CControlPacketError;

    pub fn init(
        code: CPacketCode,
        key_value: u8,
        session_id: []const u8,
        packet_id: u32,
        payload_value: ?[]const u8,
        ack_ids_value: ?[]const u32,
        ack_remote_session_id_value: ?[]const u8,
    ) InitError!CControlPacket {
        if (key_value > 0b111) return error.InvalidKey;
        if (session_id.len != c.OpenVPNPacketSessionIdLength) return error.InvalidSessionId;
        if (ack_ids_value) |ids| {
            if (ids.len == 0 or ids.len > std.math.maxInt(u8)) return error.AckIdsTooLong;
            const remote = ack_remote_session_id_value orelse return error.InvalidAck;
            if (remote.len != c.OpenVPNPacketSessionIdLength) return error.InvalidSessionId;
        } else if (ack_remote_session_id_value != null) {
            return error.InvalidAck;
        }
        if (code == .ackV1) {
            if (packet_id != std.math.maxInt(u32) or ack_ids_value == null or payload_value != null)
                return error.InvalidAck;
        } else if (packet_id == std.math.maxInt(u32)) {
            // The native capacity helper identifies ACKs by this sentinel,
            // while its serializer identifies them by opcode. Rejecting the
            // inconsistent state prevents an undersized native allocation.
            return error.InvalidPacketId;
        }

        const payload_ptr = if (payload_value) |bytes|
            if (bytes.len == 0) null else bytes.ptr
        else
            null;
        const ack_ids_ptr = if (ack_ids_value) |ids| ids.ptr else null;
        const ack_remote_ptr = if (ack_remote_session_id_value) |remote| remote.ptr else null;
        const native_packet = c.openvpn_ctrl_create(
            code.native(),
            key_value,
            packet_id,
            session_id.ptr,
            payload_ptr,
            if (payload_value) |bytes| bytes.len else 0,
            ack_ids_ptr,
            if (ack_ids_value) |ids| ids.len else 0,
            ack_remote_ptr,
        );
        return .{ .ptr = native_packet, .code = code };
    }

    pub fn initAck(
        key_value: u8,
        session_id: []const u8,
        ack_ids_value: []const u32,
        ack_remote_session_id_value: []const u8,
    ) InitError!CControlPacket {
        return init(
            .ackV1,
            key_value,
            session_id,
            std.math.maxInt(u32),
            null,
            ack_ids_value,
            ack_remote_session_id_value,
        );
    }

    pub fn deinit(self: *CControlPacket) void {
        if (self.ptr) |ptr| c.openvpn_ctrl_free(ptr);
        self.ptr = null;
    }

    /// Transfers ownership and leaves `self` in a valid, empty state.
    pub fn move(self: *CControlPacket) CControlPacket {
        const result = self.*;
        self.ptr = null;
        return result;
    }

    pub fn native(self: *const CControlPacket) *c.openvpn_ctrl {
        return self.ptr orelse @panic("use of moved CControlPacket");
    }

    pub fn key(self: *const CControlPacket) u8 {
        return self.native().key;
    }

    pub fn sessionId(self: *const CControlPacket) []const u8 {
        return self.native().session_id[0..c.OpenVPNPacketSessionIdLength];
    }

    pub fn packetId(self: *const CControlPacket) u32 {
        return self.native().packet_id;
    }

    pub fn payload(self: *const CControlPacket) ?[]const u8 {
        const native_packet = self.native();
        const bytes = native_packet.payload orelse return null;
        return bytes[0..native_packet.payload_len];
    }

    pub fn ackIds(self: *const CControlPacket) ?[]const u32 {
        const native_packet = self.native();
        const ids = native_packet.ack_ids orelse return null;
        return ids[0..native_packet.ack_ids_len];
    }

    pub fn ackRemoteSessionId(self: *const CControlPacket) ?[]const u8 {
        const bytes = self.native().ack_remote_session_id orelse return null;
        return bytes[0..c.OpenVPNPacketSessionIdLength];
    }

    pub fn isAck(self: *const CControlPacket) bool {
        return self.packetId() == std.math.maxInt(u32);
    }

    /// Caller-owned equivalent of Swift's sensitive debug description.
    pub fn debugDescriptionAlloc(
        self: *const CControlPacket,
        allocator: std.mem.Allocator,
        with_sensitive_data: bool,
    ) std.mem.Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeByte('{') catch return error.OutOfMemory;
        writer.print("{s} | {}, sid: ", .{ self.code.debugName(), self.key() }) catch
            return error.OutOfMemory;
        writeHex(writer, self.sessionId()) catch return error.OutOfMemory;
        if (self.ackIds()) |ack_ids| {
            const remote_session_id = self.ackRemoteSessionId().?;
            writer.writeAll(", acks: {[") catch return error.OutOfMemory;
            for (ack_ids, 0..) |ack_id, index| {
                if (index > 0) writer.writeAll(", ") catch return error.OutOfMemory;
                writer.print("{}", .{ack_id}) catch return error.OutOfMemory;
            }
            writer.writeAll("], ") catch return error.OutOfMemory;
            writeHex(writer, remote_session_id) catch return error.OutOfMemory;
            writer.writeByte('}') catch return error.OutOfMemory;
        }
        if (!self.isAck()) {
            writer.print(", pid: {}", .{self.packetId()}) catch return error.OutOfMemory;
        }
        if (self.payload()) |payload_bytes| {
            writer.print(", [{} bytes", .{payload_bytes.len}) catch return error.OutOfMemory;
            if (with_sensitive_data) {
                writer.writeAll(", ") catch return error.OutOfMemory;
                writeHex(writer, payload_bytes) catch return error.OutOfMemory;
            }
            writer.writeByte(']') catch return error.OutOfMemory;
        }
        writer.writeByte('}') catch return error.OutOfMemory;
        return output.toOwnedSlice() catch error.OutOfMemory;
    }

    pub fn serializedAlloc(
        self: *const CControlPacket,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]u8 {
        const packet = self.native();
        const capacity = c.openvpn_ctrl_capacity(packet);
        const destination = try allocator.alloc(u8, capacity);
        errdefer allocator.free(destination);
        const header_length = c.openvpn_packet_header_set(
            destination.ptr,
            packet.code,
            packet.key,
            packet.session_id,
        );
        const serialized_length = c.openvpn_ctrl_serialize(destination.ptr + header_length, packet);
        const written = header_length + serialized_length;
        std.debug.assert(written == capacity);
        return destination;
    }

    pub fn serializedWithCryptoAlloc(
        self: *const CControlPacket,
        allocator: std.mem.Allocator,
        crypto: c_crypto.pp_crypto_ctx,
        replay_id: u32,
        timestamp: u32,
        function: anytype,
    ) anyerror![]u8 {
        const packet = self.native();
        var algorithm = c.openvpn_ctrl_alg{
            .crypto = @ptrCast(crypto),
            .replay_id = replay_id,
            .timestamp = timestamp,
        };
        const capacity = c.openvpn_ctrl_capacity_alg(packet, &algorithm);
        var destination = try allocator.alloc(u8, capacity);
        errdefer allocator.free(destination);
        var native_error: c_crypto.pp_crypto_error_code = c_crypto.PPCryptoErrorNone;
        const written = function(
            destination.ptr,
            destination.len,
            packet,
            &algorithm,
            @ptrCast(&native_error),
        );
        if (written == 0) return errors.CCryptoError.init(native_error).toError();
        if (written < destination.len) destination = try allocator.realloc(destination, written);
        return destination;
    }
};

fn writeHex(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
}

test "control packet serializes to the Swift wire vector" {
    const session_id = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const payload = [_]u8{ 0x93, 0x27, 0x48, 0x23, 0x87, 0x42, 0x39, 0x75, 0x91, 0x70, 0x48, 0x91 };
    var packet = try CControlPacket.init(.controlV1, 3, &session_id, 0x1456, &payload, null, null);
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
    var packet = try CControlPacket.initAck(3, &session_id, &ids, &remote_id);
    defer packet.deinit();
    const serialized = try packet.serializedAlloc(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    try std.testing.expectEqual(@as(u8, 0x2b), serialized[0]);
    try std.testing.expectEqual(@as(u8, 2), serialized[9]);
    try std.testing.expectEqualSlices(u8, &remote_id, serialized[18..26]);
}

test "move prevents duplicate C ownership" {
    const id = [_]u8{0} ** c.OpenVPNPacketSessionIdLength;
    var source = try CControlPacket.init(.controlV1, 0, &id, 0, null, null, null);
    var destination = source.move();
    defer destination.deinit();
    try std.testing.expect(source.ptr == null);
}

test "control packet rejects the native ACK sentinel on data opcodes" {
    const id = [_]u8{0} ** c.OpenVPNPacketSessionIdLength;
    try std.testing.expectError(
        error.InvalidPacketId,
        CControlPacket.init(.controlV1, 0, &id, std.math.maxInt(u32), null, null, null),
    );
}

test "control packet diagnostic redacts only payload bytes" {
    const id = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    const payload = [_]u8{ 0xde, 0xad };
    var packet = try CControlPacket.init(.controlV1, 2, &id, 7, &payload, null, null);
    defer packet.deinit();

    const redacted = try packet.debugDescriptionAlloc(std.testing.allocator, false);
    defer std.testing.allocator.free(redacted);
    try std.testing.expectEqualStrings(
        "{CONTROL_V1 | 2, sid: 0123456789abcdef, pid: 7, [2 bytes]}",
        redacted,
    );

    const sensitive = try packet.debugDescriptionAlloc(std.testing.allocator, true);
    defer std.testing.allocator.free(sensitive);
    try std.testing.expectEqualStrings(
        "{CONTROL_V1 | 2, sid: 0123456789abcdef, pid: 7, [2 bytes, dead]}",
        sensitive,
    );
}
