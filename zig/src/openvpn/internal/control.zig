// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const c_crypto = @import("../../c/exports.zig").crypto;
const c = @import("c.zig").api;
const errors = @import("errors.zig");
const PRNG = @import("prng.zig").PRNG;

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

    pub fn debugName(self: PacketCode) []const u8 {
        return switch (self) {
            .softResetV1 => "SOFT_RESET_V1",
            .controlV1 => "CONTROL_V1",
            .ackV1 => "ACK_V1",
            .dataV1 => "DATA_V1",
            .hardResetClientV2 => "HARD_RESET_CLIENT_V2",
            .hardResetServerV2 => "HARD_RESET_SERVER_V2",
            .dataV2 => "DATA_V2",
            .hardResetClientV3 => "HARD_RESET_CLIENT_V3",
            .controlWkcV1 => "CONTROL_WKC_V1",
            .unknown => "UNKNOWN(255)",
        };
    }
};

test "packet code wire values match OpenVPN" {
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(PacketCode.controlV1));
    try std.testing.expectEqual(PacketCode.hardResetClientV3, PacketCode.fromRaw(0x0a).?);
    try std.testing.expect(PacketCode.fromRaw(0x7f) == null);
    try std.testing.expectEqualStrings("UNKNOWN(255)", PacketCode.unknown.debugName());
}

pub const ControlPacket = struct {
    ptr: ?*c.openvpn_ctrl,
    code: PacketCode,

    pub const InitError = errors.ControlPacketError;

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

    pub fn isAck(self: *const ControlPacket) bool {
        return self.packetId() == std.math.maxInt(u32);
    }

    /// Caller-owned equivalent of Swift's sensitive debug description.
    pub fn debugDescriptionAlloc(
        self: *const ControlPacket,
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
        if (written == 0) return errors.cryptoError(native_error);
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
    const id = [_]u8{0} ** c.OpenVPNPacketSessionIdLength;
    var source = try ControlPacket.init(.controlV1, 0, &id, 0, null, null, null);
    var destination = source.move();
    defer destination.deinit();
    try std.testing.expect(source.ptr == null);
}

test "control packet rejects the native ACK sentinel on data opcodes" {
    const id = [_]u8{0} ** c.OpenVPNPacketSessionIdLength;
    try std.testing.expectError(
        error.InvalidPacketId,
        ControlPacket.init(.controlV1, 0, &id, std.math.maxInt(u32), null, null, null),
    );
}

test "control packet diagnostic redacts only payload bytes" {
    const id = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    const payload = [_]u8{ 0xde, 0xad };
    var packet = try ControlPacket.init(.controlV1, 2, &id, 7, &payload, null, null);
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

pub fn ControlChannel(comptime Serializer: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        prng: PRNG,
        serializer: Serializer,
        session_id: ?[c.OpenVPNPacketSessionIdLength]u8 = null,
        remote_session_id: ?[c.OpenVPNPacketSessionIdLength]u8 = null,
        inbound_queue: std.ArrayList(ControlPacket) = .empty,
        outbound_queue: std.ArrayList(ControlPacket) = .empty,
        current_inbound_id: u32 = 0,
        current_outbound_id: u32 = 0,
        pending_acks: std.AutoHashMap(u32, void),
        sent_dates_ms: std.AutoHashMap(u32, u64),

        /// Takes ownership of `serializer`, including when allocation fails.
        pub fn create(
            allocator: std.mem.Allocator,
            prng: PRNG,
            serializer: Serializer,
        ) std.mem.Allocator.Error!*Self {
            var owned_serializer = serializer;
            errdefer owned_serializer.deinit(allocator);
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .prng = prng,
                .serializer = owned_serializer,
                .pending_acks = std.AutoHashMap(u32, void).init(allocator),
                .sent_dates_ms = std.AutoHashMap(u32, u64).init(allocator),
            };
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.clearPacketList(&self.inbound_queue);
            self.clearPacketList(&self.outbound_queue);
            self.inbound_queue.deinit(self.allocator);
            self.outbound_queue.deinit(self.allocator);
            self.pending_acks.deinit();
            self.sent_dates_ms.deinit();
            self.serializer.deinit(self.allocator);
            const allocator = self.allocator;
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn reset(self: *Self, for_new_session: bool) anyerror!void {
            if (for_new_session) {
                var local: [c.OpenVPNPacketSessionIdLength]u8 = undefined;
                try self.prng.fill(&local);
                self.session_id = local;
                self.remote_session_id = null;
            }
            self.clearPacketList(&self.inbound_queue);
            self.clearPacketList(&self.outbound_queue);
            self.current_inbound_id = 0;
            self.current_outbound_id = 0;
            self.pending_acks.clearRetainingCapacity();
            self.sent_dates_ms.clearRetainingCapacity();
            self.serializer.reset();
        }

        pub fn sessionId(self: *const Self) ?[]const u8 {
            return if (self.session_id) |*value| value else null;
        }

        pub fn remoteSessionId(self: *const Self) ?[]const u8 {
            return if (self.remote_session_id) |*value| value else null;
        }

        pub fn setRemoteSessionId(self: *Self, value: []const u8) errors.InvalidSessionIdError!void {
            if (value.len != c.OpenVPNPacketSessionIdLength) return error.InvalidSessionId;
            var copy: [c.OpenVPNPacketSessionIdLength]u8 = undefined;
            @memcpy(&copy, value);
            self.remote_session_id = copy;
        }

        pub fn readInboundPacket(
            self: *Self,
            data: []const u8,
            offset: usize,
        ) anyerror!ControlPacket {
            var packet = try self.serializer.deserialize(self.allocator, data, offset, null);
            errdefer packet.deinit();
            if (packet.ackIds()) |ids| {
                const remote = packet.ackRemoteSessionId() orelse return error.InvalidAck;
                try self.readAcks(ids, remote);
            }
            return packet;
        }

        /// Takes ownership of `packet`. The returned slice storage and every
        /// packet in it are owned by the caller, which must deinit the packets and
        /// free the slice with this channel's allocator.
        pub fn enqueueInboundPacket(
            self: *Self,
            packet: ControlPacket,
        ) std.mem.Allocator.Error![]ControlPacket {
            var owned = packet;
            self.inbound_queue.append(self.allocator, owned) catch |err| {
                owned.deinit();
                return err;
            };
            std.sort.heap(ControlPacket, self.inbound_queue.items, {}, packetLessThan);

            var ready: std.ArrayList(ControlPacket) = .empty;
            errdefer {
                for (ready.items) |*item| item.deinit();
                ready.deinit(self.allocator);
            }
            while (self.inbound_queue.items.len > 0) {
                const first_id = self.inbound_queue.items[0].packetId();
                if (first_id < self.current_inbound_id) {
                    var duplicate = self.inbound_queue.orderedRemove(0);
                    duplicate.deinit();
                    continue;
                }
                if (first_id != self.current_inbound_id) break;
                var next = self.inbound_queue.orderedRemove(0);
                ready.append(self.allocator, next) catch |err| {
                    next.deinit();
                    return err;
                };
                self.current_inbound_id +%= 1;
            }
            return ready.toOwnedSlice(self.allocator);
        }

        pub fn enqueueOutboundPacketsWithCode(
            self: *Self,
            code: PacketCode,
            key: u8,
            payload: []const u8,
            max_payload_bytes_per_packet: usize,
        ) anyerror!void {
            return self.enqueueOutboundPackets(
                code,
                code,
                key,
                payload,
                max_payload_bytes_per_packet,
                max_payload_bytes_per_packet,
            );
        }

        pub fn enqueueOutboundPackets(
            self: *Self,
            leading_code: PacketCode,
            trailing_code: PacketCode,
            key: u8,
            payload: []const u8,
            leading_payload_byte_limit: usize,
            trailing_payload_byte_limit: usize,
        ) anyerror!void {
            const local_session_id = self.sessionId() orelse return error.MissingSessionId;
            if (payload.len > 0 and leading_payload_byte_limit == 0) return error.ControlChannelFailure;
            if (payload.len > 0 and trailing_payload_byte_limit == 0) return error.ControlChannelFailure;

            var offset: usize = 0;
            var leading = true;
            while (true) {
                const limit = if (leading) leading_payload_byte_limit else trailing_payload_byte_limit;
                const remaining = payload.len - offset;
                const payload_length = @min(limit, remaining);
                const code = if (leading) leading_code else trailing_code;
                var packet = try ControlPacket.init(
                    code,
                    key,
                    local_session_id,
                    self.current_outbound_id,
                    payload[offset .. offset + payload_length],
                    null,
                    null,
                );
                errdefer packet.deinit();
                try self.outbound_queue.append(self.allocator, packet);
                self.current_outbound_id +%= 1;
                offset += payload_length;
                if (offset >= payload.len) break;
                leading = false;
            }
        }

        pub fn writeOutboundPackets(
            self: *Self,
            resend_after_ms: i64,
        ) anyerror![][]u8 {
            var raw_packets: std.ArrayList([]u8) = .empty;
            errdefer freePacketList(self.allocator, &raw_packets);
            const now = core.concurrency.monotonicNs() / std.time.ns_per_ms;
            for (self.outbound_queue.items) |*packet| {
                if (self.sent_dates_ms.get(packet.packetId())) |sent| {
                    if (resend_after_ms > 0 and now -| sent < @as(u64, @intCast(resend_after_ms))) continue;
                }
                const raw = try self.serializer.serialize(self.allocator, packet);
                raw_packets.append(self.allocator, raw) catch |err| {
                    self.allocator.free(raw);
                    return err;
                };
                try self.sent_dates_ms.put(packet.packetId(), now);
                try self.pending_acks.put(packet.packetId(), {});
            }
            return raw_packets.toOwnedSlice(self.allocator);
        }

        pub fn hasPendingAcks(self: *const Self) bool {
            return self.pending_acks.count() > 0;
        }

        pub fn writeAcks(
            self: *Self,
            key: u8,
            ack_packet_ids: []const u32,
            ack_remote_session_id: []const u8,
        ) anyerror![]u8 {
            const local_session_id = self.sessionId() orelse return error.MissingSessionId;
            var packet = try ControlPacket.initAck(
                key,
                local_session_id,
                ack_packet_ids,
                ack_remote_session_id,
            );
            defer packet.deinit();
            return self.serializer.serialize(self.allocator, &packet);
        }

        pub fn freePackets(allocator: std.mem.Allocator, packets: [][]u8) void {
            for (packets) |packet| allocator.free(packet);
            allocator.free(packets);
        }

        fn readAcks(
            self: *Self,
            packet_ids: []const u32,
            acks_remote_session_id: []const u8,
        ) anyerror!void {
            const local_session_id = self.sessionId() orelse return error.MissingSessionId;
            if (!std.mem.eql(u8, acks_remote_session_id, local_session_id)) return error.SessionMismatch;

            var index: usize = 0;
            while (index < self.outbound_queue.items.len) {
                const packet_id = self.outbound_queue.items[index].packetId();
                if (std.mem.indexOfScalar(u32, packet_ids, packet_id) != null) {
                    var acknowledged = self.outbound_queue.orderedRemove(index);
                    acknowledged.deinit();
                } else {
                    index += 1;
                }
            }
            for (packet_ids) |packet_id| {
                _ = self.pending_acks.remove(packet_id);
            }
        }

        fn clearPacketList(self: *Self, packets: *std.ArrayList(ControlPacket)) void {
            _ = self;
            for (packets.items) |*packet| packet.deinit();
            packets.clearRetainingCapacity();
        }

        fn packetLessThan(_: void, lhs: ControlPacket, rhs: ControlPacket) bool {
            return lhs.packetId() < rhs.packetId();
        }

        fn freePacketList(allocator: std.mem.Allocator, packets: *std.ArrayList([]u8)) void {
            for (packets.items) |packet| allocator.free(packet);
            packets.deinit(allocator);
        }
    };
}
