// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const c_mod = @import("c.zig");
const crypto_mod = @import("crypto.zig");
const errors_mod = @import("errors.zig");
const packet_mod = @import("packet.zig");

const c = c_mod.api;

const ControlPacket = packet_mod.ControlPacket;
const PacketCode = packet_mod.PacketCode;
const PRNG = crypto_mod.PRNG;

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

        pub fn reset(self: *Self, for_new_session: bool) !void {
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

        pub fn setRemoteSessionId(self: *Self, value: []const u8) errors_mod.InvalidSessionIdError!void {
            if (value.len != c.OpenVPNPacketSessionIdLength) return error.InvalidSessionId;
            var copy: [c.OpenVPNPacketSessionIdLength]u8 = undefined;
            @memcpy(&copy, value);
            self.remote_session_id = copy;
        }

        pub fn readInboundPacket(
            self: *Self,
            data: []const u8,
            offset: usize,
        ) !ControlPacket {
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

        pub fn enqueueOutboundPackets(
            self: *Self,
            leading_code: PacketCode,
            trailing_code: PacketCode,
            key: u8,
            payload: []const u8,
            leading_payload_byte_limit: usize,
            trailing_payload_byte_limit: usize,
        ) !void {
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
        ) ![][]u8 {
            var raw_packets: std.ArrayList([]u8) = .empty;
            errdefer freePacketList(self.allocator, &raw_packets);
            const now = core_mod.concurrency.monotonicNs() / std.time.ns_per_ms;
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

        pub fn writeAcks(
            self: *Self,
            key: u8,
            ack_packet_ids: []const u32,
            ack_remote_session_id: []const u8,
        ) ![]u8 {
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

        fn readAcks(
            self: *Self,
            packet_ids: []const u32,
            acks_remote_session_id: []const u8,
        ) !void {
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
