// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Zig ownership wrapper for the existing OpenVPN packet processor C API.

const std = @import("std");

const api = @import("../../core/exports.zig").api;
const c = @import("c.zig").api;
const errors = @import("errors.zig");

extern fn partout_openvpn_pkt_proc_stream_recv(
    processor: *const c.openvpn_pkt_proc,
    source: [*c]const u8,
    source_length: usize,
    source_received: *usize,
) ?*c.pp_zd;

extern fn partout_openvpn_pkt_proc_stream_send(
    processor: *const c.openvpn_pkt_proc,
    destination: *c.pp_zd,
    destination_offset: usize,
    source: [*c]const u8,
    source_length: usize,
) usize;
const Direction = @import("packet_direction.zig").Direction;

pub const PacketProcessor = struct {
    ptr: *c.openvpn_pkt_proc,

    pub fn init(
        allocator: std.mem.Allocator,
        method: ?api.OpenVPNObfuscationMethod,
    ) (std.mem.Allocator.Error || api.EncodeError)!PacketProcessor {
        var native_method: c.openvpn_pkt_proc_method = c.OpenVPNPktProcMethodNone;
        var mask: ?[]u8 = null;
        defer if (mask) |bytes| allocator.free(bytes);

        if (method) |value| switch (value) {
            .xormask => |parameters| {
                native_method = c.OpenVPNPktProcMethodXORMask;
                mask = try parameters.mask.bytesAlloc(allocator);
            },
            .xorptrpos => native_method = c.OpenVPNPktProcMethodXORPtrPos,
            .reverse => native_method = c.OpenVPNPktProcMethodReverse,
            .obfuscate => |parameters| {
                native_method = c.OpenVPNPktProcMethodXORObfuscate;
                mask = try parameters.mask.bytesAlloc(allocator);
            },
        };

        const native = c.openvpn_pkt_proc_create(
            native_method,
            if (mask) |bytes| bytes.ptr else null,
            if (mask) |bytes| bytes.len else 0,
        );
        return .{ .ptr = native };
    }

    pub fn deinit(self: *PacketProcessor) void {
        c.openvpn_pkt_proc_free(self.ptr);
        self.ptr = undefined;
    }

    pub fn processPacket(
        self: *const PacketProcessor,
        allocator: std.mem.Allocator,
        packet: []const u8,
        direction: Direction,
    ) std.mem.Allocator.Error![]u8 {
        const destination = try allocator.alloc(u8, packet.len);
        switch (direction) {
            .inbound => c.openvpn_pkt_proc_recv(self.ptr, destination.ptr, packet.ptr, packet.len),
            .outbound => c.openvpn_pkt_proc_send(self.ptr, destination.ptr, packet.ptr, packet.len),
        }
        return destination;
    }

    pub fn processPackets(
        self: *const PacketProcessor,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
        direction: Direction,
    ) std.mem.Allocator.Error![][]u8 {
        const result = try allocator.alloc([]u8, packets.len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |packet| allocator.free(packet);
            allocator.free(result);
        }
        for (packets, result) |packet, *destination| {
            destination.* = try self.processPacket(allocator, packet, direction);
            initialized += 1;
        }
        return result;
    }

    pub fn packetsFromStream(
        self: *const PacketProcessor,
        allocator: std.mem.Allocator,
        stream: []const u8,
        until: *usize,
    ) std.mem.Allocator.Error![][]u8 {
        var packets: std.ArrayList([]u8) = .empty;
        errdefer freePacketList(allocator, &packets);
        until.* = 0;
        while (until.* < stream.len) {
            var received: usize = 0;
            const zeroing = partout_openvpn_pkt_proc_stream_recv(
                self.ptr,
                stream[until.*..].ptr,
                stream.len - until.*,
                &received,
            ) orelse break;
            defer c.pp_zd_free(zeroing);
            const copy = try allocator.dupe(u8, zeroing.*.bytes[0..zeroing.*.length]);
            errdefer allocator.free(copy);
            try packets.append(allocator, copy);
            until.* += received;
        }
        return packets.toOwnedSlice(allocator);
    }

    pub fn streamFromPacket(
        self: *const PacketProcessor,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) (std.mem.Allocator.Error || errors.PacketProcessorError)![]u8 {
        return self.streamFromPackets(allocator, &.{packet});
    }

    pub fn streamFromPackets(
        self: *const PacketProcessor,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) (std.mem.Allocator.Error || errors.PacketProcessorError)![]u8 {
        var payload_length: usize = 0;
        for (packets) |packet| {
            if (packet.len > std.math.maxInt(u16)) return error.PacketTooLarge;
            payload_length = std.math.add(usize, payload_length, packet.len) catch return error.PacketTooLarge;
        }
        const capacity = c.openvpn_pkt_proc_stream_send_bufsize(@intCast(packets.len), payload_length);
        const zeroing = c.pp_zd_create(capacity);
        defer c.pp_zd_free(zeroing);
        var offset: usize = 0;
        for (packets) |packet| {
            offset = partout_openvpn_pkt_proc_stream_send(
                self.ptr,
                zeroing,
                offset,
                packet.ptr,
                packet.len,
            );
        }
        std.debug.assert(offset == capacity);
        return allocator.dupe(u8, zeroing.*.bytes[0..offset]);
    }

    pub fn freePackets(allocator: std.mem.Allocator, packets: [][]u8) void {
        for (packets) |packet| allocator.free(packet);
        allocator.free(packets);
    }

    fn freePacketList(allocator: std.mem.Allocator, packets: *std.ArrayList([]u8)) void {
        for (packets.items) |packet| allocator.free(packet);
        packets.deinit(allocator);
    }
};

test "packet processor frames and parses a TCP stream" {
    var processor = try PacketProcessor.init(std.testing.allocator, null);
    defer processor.deinit();
    const packet = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    const stream = try processor.streamFromPacket(std.testing.allocator, &packet);
    defer std.testing.allocator.free(stream);
    try std.testing.expectEqualSlices(u8, &.{ 0, 5, 0x11, 0x22, 0x33, 0x44, 0x55 }, stream);

    var consumed: usize = 0;
    const parsed = try processor.packetsFromStream(std.testing.allocator, stream, &consumed);
    defer PacketProcessor.freePackets(std.testing.allocator, parsed);
    try std.testing.expectEqual(stream.len, consumed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualSlices(u8, &packet, parsed[0]);
}

test "packet processor retains incomplete TCP frames" {
    var processor = try PacketProcessor.init(std.testing.allocator, null);
    defer processor.deinit();
    var consumed: usize = 99;
    const parsed = try processor.packetsFromStream(std.testing.allocator, &.{ 0, 4, 1, 2 }, &consumed);
    defer PacketProcessor.freePackets(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 0), consumed);
    try std.testing.expectEqual(@as(usize, 0), parsed.len);
}
