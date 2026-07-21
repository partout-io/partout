// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const api = @import("../../core/exports.zig").api;
const AuthSerializer = @import("auth_serializer.zig").AuthSerializer;
const c_crypto = @import("../../c/exports.zig").crypto;
const c = @import("c.zig").api;
const CControlPacket = @import("c_control_packet.zig").CControlPacket;
const CPacketCode = @import("c_packet_code.zig").CPacketCode;
const configuration_helpers = @import("configuration_helpers.zig");
const ControlChannelSerializer = @import("control_channel_serializer.zig").ControlChannelSerializer;
const CryptSerializer = @import("crypt_serializer.zig").CryptSerializer;
const CryptV2Serializer = @import("crypt_v2_serializer.zig").CryptV2Serializer;
const errors = @import("errors.zig");
const PlainSerializer = @import("plain_serializer.zig").PlainSerializer;
const PRNG = @import("prng.zig").PRNG;

pub const ControlChannelV3 = struct {
    allocator: std.mem.Allocator,
    prng: PRNG,
    serializer: ControlChannelSerializer,
    session_id: ?[c.OpenVPNPacketSessionIdLength]u8 = null,
    remote_session_id: ?[c.OpenVPNPacketSessionIdLength]u8 = null,
    inbound_queue: std.ArrayList(CControlPacket) = .empty,
    outbound_queue: std.ArrayList(CControlPacket) = .empty,
    current_inbound_id: u32 = 0,
    current_outbound_id: u32 = 0,
    pending_acks: std.AutoHashMap(u32, void),
    sent_dates_ms: std.AutoHashMap(u32, u64),

    /// Takes ownership of `serializer_value`; callers with a named serializer
    /// should pass `serializer.move()`.
    pub fn create(
        allocator: std.mem.Allocator,
        prng: PRNG,
        serializer_value: ControlChannelSerializer,
    ) std.mem.Allocator.Error!*ControlChannelV3 {
        var serializer = serializer_value;
        errdefer serializer.deinit(allocator);
        const self = try allocator.create(ControlChannelV3);
        self.* = .{
            .allocator = allocator,
            .prng = prng,
            .serializer = serializer.move(),
            .pending_acks = std.AutoHashMap(u32, void).init(allocator),
            .sent_dates_ms = std.AutoHashMap(u32, u64).init(allocator),
        };
        return self;
    }

    pub fn createForConfiguration(
        allocator: std.mem.Allocator,
        fnt: c_crypto.pp_crypto_enc_fnt,
        prng: PRNG,
        configuration: *const api.OpenVPNConfiguration,
    ) anyerror!*ControlChannelV3 {
        var serializer = if (configuration.tls_wrap) |wrap| switch (wrap.strategy) {
            .auth => try AuthSerializer.create(
                allocator,
                fnt,
                configuration_helpers.fallbackDigest(configuration.*),
                wrap.key,
            ),
            .crypt => try CryptSerializer.create(allocator, fnt, wrap.key),
            .cryptV2 => try CryptV2Serializer.create(
                allocator,
                fnt,
                wrap.key,
                wrap.wrapped_key orelse return error.Assertion,
            ),
        } else try PlainSerializer.create(allocator);
        errdefer serializer.deinit(allocator);
        return create(allocator, prng, serializer.move());
    }

    pub fn destroy(self: *ControlChannelV3) void {
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

    pub fn reset(self: *ControlChannelV3, for_new_session: bool) anyerror!void {
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

    pub fn sessionId(self: *const ControlChannelV3) ?[]const u8 {
        return if (self.session_id) |*value| value else null;
    }

    pub fn remoteSessionId(self: *const ControlChannelV3) ?[]const u8 {
        return if (self.remote_session_id) |*value| value else null;
    }

    pub fn setRemoteSessionId(self: *ControlChannelV3, value: []const u8) errors.InvalidSessionIdError!void {
        if (value.len != c.OpenVPNPacketSessionIdLength) return error.InvalidSessionId;
        var copy: [c.OpenVPNPacketSessionIdLength]u8 = undefined;
        @memcpy(&copy, value);
        self.remote_session_id = copy;
    }

    pub fn readInboundPacket(
        self: *ControlChannelV3,
        data: []const u8,
        offset: usize,
    ) anyerror!CControlPacket {
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
        self: *ControlChannelV3,
        packet: CControlPacket,
    ) std.mem.Allocator.Error![]CControlPacket {
        var owned = packet;
        self.inbound_queue.append(self.allocator, owned) catch |err| {
            owned.deinit();
            return err;
        };
        std.sort.heap(CControlPacket, self.inbound_queue.items, {}, packetLessThan);

        var ready: std.ArrayList(CControlPacket) = .empty;
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
        self: *ControlChannelV3,
        code: CPacketCode,
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
        self: *ControlChannelV3,
        leading_code: CPacketCode,
        trailing_code: CPacketCode,
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
            var packet = try CControlPacket.init(
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
        self: *ControlChannelV3,
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

    pub fn hasPendingAcks(self: *const ControlChannelV3) bool {
        return self.pending_acks.count() > 0;
    }

    pub fn writeAcks(
        self: *ControlChannelV3,
        key: u8,
        ack_packet_ids: []const u32,
        ack_remote_session_id: []const u8,
    ) anyerror![]u8 {
        const local_session_id = self.sessionId() orelse return error.MissingSessionId;
        var packet = try CControlPacket.initAck(
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
        self: *ControlChannelV3,
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

    fn clearPacketList(self: *ControlChannelV3, packets: *std.ArrayList(CControlPacket)) void {
        _ = self;
        for (packets.items) |*packet| packet.deinit();
        packets.clearRetainingCapacity();
    }

    fn packetLessThan(_: void, lhs: CControlPacket, rhs: CControlPacket) bool {
        return lhs.packetId() < rhs.packetId();
    }

    fn freePacketList(allocator: std.mem.Allocator, packets: *std.ArrayList([]u8)) void {
        for (packets.items) |packet| allocator.free(packet);
        packets.deinit(allocator);
    }
};

test "plain control channel fragments payload and retains opcode" {
    var one: u8 = 1;
    const mock_prng = PRNG{ .context = &one, .fill_fn = fillOnes };
    var serializer = try PlainSerializer.create(std.testing.allocator);
    errdefer serializer.deinit(std.testing.allocator);
    const channel = try ControlChannelV3.create(std.testing.allocator, mock_prng, serializer.move());
    defer channel.destroy();
    try channel.reset(true);
    try channel.enqueueOutboundPacketsWithCode(.controlV1, 0, &.{ 1, 2, 3, 4, 5, 6 }, 4);
    const packets = try channel.writeOutboundPackets(0);
    defer ControlChannelV3.freePackets(std.testing.allocator, packets);
    try std.testing.expectEqual(@as(usize, 2), packets.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(CPacketCode.controlV1)), packets[0][0] >> 3);
    try std.testing.expectEqual(@as(u8, @intFromEnum(CPacketCode.controlV1)), packets[1][0] >> 3);
}

test "control channel reorders and deduplicates inbound packets" {
    var one: u8 = 1;
    const mock_prng = PRNG{ .context = &one, .fill_fn = fillOnes };
    var serializer = try PlainSerializer.create(std.testing.allocator);
    errdefer serializer.deinit(std.testing.allocator);
    const channel = try ControlChannelV3.create(std.testing.allocator, mock_prng, serializer.move());
    defer channel.destroy();
    try channel.reset(true);
    const sid = channel.sessionId().?;
    const sequence = [_]u32{ 2, 0, 1, 1 };
    var handled: std.ArrayList(u32) = .empty;
    defer handled.deinit(std.testing.allocator);
    for (sequence) |packet_id| {
        const packet = try CControlPacket.init(.controlV1, 0, sid, packet_id, null, null, null);
        const ready = try channel.enqueueInboundPacket(packet);
        defer std.testing.allocator.free(ready);
        for (ready) |*item| {
            try handled.append(std.testing.allocator, item.packetId());
            item.deinit();
        }
    }
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, handled.items);
}

test "control channel suppresses retransmission until ACK" {
    var one: u8 = 1;
    const mock_prng = PRNG{ .context = &one, .fill_fn = fillOnes };
    var serializer = try PlainSerializer.create(std.testing.allocator);
    errdefer serializer.deinit(std.testing.allocator);
    const channel = try ControlChannelV3.create(std.testing.allocator, mock_prng, serializer.move());
    defer channel.destroy();
    try channel.reset(true);
    try channel.enqueueOutboundPacketsWithCode(.controlV1, 0, "hello", 64);

    const first_write = try channel.writeOutboundPackets(60_000);
    defer ControlChannelV3.freePackets(std.testing.allocator, first_write);
    try std.testing.expectEqual(@as(usize, 1), first_write.len);
    try std.testing.expect(channel.hasPendingAcks());

    const suppressed = try channel.writeOutboundPackets(60_000);
    defer ControlChannelV3.freePackets(std.testing.allocator, suppressed);
    try std.testing.expectEqual(@as(usize, 0), suppressed.len);

    const packet_ids = [_]u32{0};
    const raw_ack = try channel.writeAcks(0, &packet_ids, channel.sessionId().?);
    defer std.testing.allocator.free(raw_ack);
    var ack = try channel.readInboundPacket(raw_ack, 0);
    defer ack.deinit();
    try std.testing.expect(!channel.hasPendingAcks());
    try std.testing.expectEqual(@as(usize, 0), channel.outbound_queue.items.len);
    // Swift retains send dates until reset, even after the corresponding ACK.
    try std.testing.expectEqual(@as(usize, 1), channel.sent_dates_ms.count());
}

fn fillOnes(context: ?*anyopaque, destination: []u8) bool {
    const value: *u8 = @ptrCast(@alignCast(context.?));
    @memset(destination, value.*);
    return true;
}
