// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const errors_mod = @import("errors.zig");
const helpers_mod = @import("helpers.zig");

const c = helpers_mod.c;
const c_crypto = c_exports_mod.crypto;

const SerializeWithCrypto = @TypeOf(&c.openvpn_ctrl_serialize_auth);

pub const PacketCode = enum(u8) {
    softResetV1 = 0x03,
    controlV1 = 0x04,
    ackV1 = 0x05,
    dataV1 = 0x06,
    hardResetClientV2 = 0x07,
    hardResetServerV2 = 0x08,
    dataV2 = 0x09,
    hardResetClientV3 = 0x0a,
    controlWkcV1 = 0x0b,
    unknown = 0xff,

    pub fn fromRaw(raw: u8) ?PacketCode {
        return switch (raw) {
            0x03 => .softResetV1,
            0x04 => .controlV1,
            0x05 => .ackV1,
            0x06 => .dataV1,
            0x07 => .hardResetClientV2,
            0x08 => .hardResetServerV2,
            0x09 => .dataV2,
            0x0a => .hardResetClientV3,
            0x0b => .controlWkcV1,
            0xff => .unknown,
            else => null,
        };
    }

    pub fn native(self: PacketCode) c.openvpn_packet_code {
        return @intFromEnum(self);
    }
};

pub const ControlPacket = struct {
    ptr: ?*c.openvpn_ctrl,
    code: PacketCode,

    pub const InitError = errors_mod.ControlPacketError;

    pub fn init(
        code: PacketCode,
        key_value: u8,
        session_id: []const u8,
        packet_id: u32,
        payload_value: ?[]const u8,
        ack_ids_value: ?[]const u32,
        ack_remote_session_id_value: ?[]const u8,
    ) InitError!ControlPacket {
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
    ) InitError!ControlPacket {
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

    pub fn deinit(self: *ControlPacket) void {
        if (self.ptr) |ptr| c.openvpn_ctrl_free(ptr);
        self.ptr = null;
    }

    /// Transfers ownership and leaves `self` in a valid, empty state.
    pub fn move(self: *ControlPacket) ControlPacket {
        const result = self.*;
        self.ptr = null;
        return result;
    }

    pub fn native(self: *const ControlPacket) *c.openvpn_ctrl {
        return self.ptr orelse @panic("use of moved ControlPacket");
    }

    pub fn key(self: *const ControlPacket) u8 {
        return self.native().key;
    }

    pub fn sessionId(self: *const ControlPacket) []const u8 {
        return self.native().session_id[0..c.OpenVPNPacketSessionIdLength];
    }

    pub fn packetId(self: *const ControlPacket) u32 {
        return self.native().packet_id;
    }

    pub fn payload(self: *const ControlPacket) ?[]const u8 {
        const native_packet = self.native();
        const bytes = native_packet.payload orelse return null;
        return bytes[0..native_packet.payload_len];
    }

    pub fn ackIds(self: *const ControlPacket) ?[]const u32 {
        const native_packet = self.native();
        const ids = native_packet.ack_ids orelse return null;
        return ids[0..native_packet.ack_ids_len];
    }

    pub fn ackRemoteSessionId(self: *const ControlPacket) ?[]const u8 {
        const bytes = self.native().ack_remote_session_id orelse return null;
        return bytes[0..c.OpenVPNPacketSessionIdLength];
    }

    pub fn serializedAlloc(
        self: *const ControlPacket,
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
        self: *const ControlPacket,
        allocator: std.mem.Allocator,
        crypto: c_crypto.pp_crypto_ctx,
        replay_id: u32,
        timestamp: u32,
        function: SerializeWithCrypto,
    ) ![]u8 {
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
        if (written == 0) return errors_mod.cryptoError(native_error);
        if (written < destination.len) destination = try allocator.realloc(destination, written);
        return destination;
    }
};

pub const OCCPacket = enum(u8) {
    exit = 0x06,

    pub const magic_string = [_]u8{
        0x28, 0x7f, 0x34, 0x6b, 0xd4, 0xef, 0x7a, 0x81,
        0x2d, 0x56, 0xb8, 0xd3, 0xaf, 0xc5, 0x45, 0x9c,
    };

    pub fn serialized(self: OCCPacket) [magic_string.len + 1]u8 {
        var result: [magic_string.len + 1]u8 = undefined;
        @memcpy(result[0..magic_string.len], &magic_string);
        result[magic_string.len] = @intFromEnum(self);
        return result;
    }
};
