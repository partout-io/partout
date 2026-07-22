// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const c_common = @import("../../c/exports.zig").common;
const c = @import("c.zig").api;
const errors = @import("errors.zig");

const api = core.api;

pub const Direction = enum {
    outbound,
    inbound,
};

pub const PacketDirection = Direction;

test "packet directions remain distinct" {
    try std.testing.expect(Direction.outbound != Direction.inbound);
}

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
            const zeroing: *c_common.pp_zd = @ptrCast(c.openvpn_pkt_proc_stream_recv(
                self.ptr,
                stream[until.*..].ptr,
                stream.len - until.*,
                &received,
            ) orelse break);
            defer c_common.pp_zd_free(zeroing);
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
        const zeroing = c_common.pp_zd_create(capacity);
        defer c_common.pp_zd_free(zeroing);
        var offset: usize = 0;
        for (packets) |packet| {
            offset = c.openvpn_pkt_proc_stream_send(
                self.ptr,
                @ptrCast(zeroing),
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

/// Applies OpenVPN XOR processing and TCP packet framing around LINK traffic.
///
/// Unlike the Swift closure pair, the Zig API returns explicit ownership. This
/// is important because `Looper.TransformWrite` returns borrowed slices: a
/// caller can keep this output alive through `Looper.write()` and release it as
/// soon as that synchronous method has copied the packets.
pub const LinkProcessor = struct {
    allocator: std.mem.Allocator,
    processor: PacketProcessor,
    is_tcp: bool,
    tcp_read_buffer: std.ArrayList(u8) = .empty,

    pub const Output = struct {
        allocator: std.mem.Allocator,
        owned_packets: [][]u8,

        pub fn packets(self: Output) []const []const u8 {
            return @ptrCast(self.owned_packets);
        }

        pub fn deinit(self: *Output) void {
            core.util.freeSliceOfStrings(self.allocator, self.owned_packets);
            self.* = undefined;
        }
    };

    pub fn create(
        allocator: std.mem.Allocator,
        method: ?api.OpenVPNObfuscationMethod,
        is_tcp: bool,
    ) anyerror!*LinkProcessor {
        const self = try allocator.create(LinkProcessor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .processor = try PacketProcessor.init(allocator, method),
            .is_tcp = is_tcp,
        };
        return self;
    }

    pub fn destroy(self: *LinkProcessor) void {
        self.tcp_read_buffer.deinit(self.allocator);
        self.processor.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn processInbound(
        self: *LinkProcessor,
        packets: []const []const u8,
    ) anyerror!Output {
        const owned = if (self.is_tcp)
            try self.processTCPInbound(packets)
        else
            try self.processor.processPackets(
                self.allocator,
                packets,
                PacketDirection.inbound,
            );
        return .{ .allocator = self.allocator, .owned_packets = owned };
    }

    pub fn processOutbound(
        self: *LinkProcessor,
        packets: []const []const u8,
    ) anyerror!Output {
        if (!self.is_tcp) {
            return .{
                .allocator = self.allocator,
                .owned_packets = try self.processor.processPackets(
                    self.allocator,
                    packets,
                    PacketDirection.outbound,
                ),
            };
        }

        const stream = try self.processor.streamFromPackets(self.allocator, packets);
        errdefer self.allocator.free(stream);
        if (stream.len == 0) {
            self.allocator.free(stream);
            return .{
                .allocator = self.allocator,
                .owned_packets = try self.allocator.alloc([]u8, 0),
            };
        }
        const result = try self.allocator.alloc([]u8, 1);
        result[0] = stream;
        return .{ .allocator = self.allocator, .owned_packets = result };
    }

    fn processTCPInbound(
        self: *LinkProcessor,
        packets: []const []const u8,
    ) anyerror![][]u8 {
        var additional: usize = 0;
        for (packets) |packet| additional = std.math.add(usize, additional, packet.len) catch return error.OutOfMemory;
        try self.tcp_read_buffer.ensureUnusedCapacity(self.allocator, additional);
        for (packets) |packet| self.tcp_read_buffer.appendSliceAssumeCapacity(packet);

        var consumed: usize = 0;
        const result = try self.processor.packetsFromStream(
            self.allocator,
            self.tcp_read_buffer.items,
            &consumed,
        );
        std.debug.assert(consumed <= self.tcp_read_buffer.items.len);
        if (consumed > 0) {
            const remaining = self.tcp_read_buffer.items[consumed..];
            std.mem.copyForwards(u8, self.tcp_read_buffer.items[0..remaining.len], remaining);
            self.tcp_read_buffer.shrinkRetainingCapacity(remaining.len);
        }
        return result;
    }
};

test "LinkProcessor declarations are semantically analyzed" {
    std.testing.refAllDecls(LinkProcessor);
}

test "LinkProcessor retains partial TCP frames and returns explicit ownership" {
    const allocator = std.testing.allocator;
    const processor = try LinkProcessor.create(allocator, null, true);
    defer processor.destroy();

    var outbound = try processor.processOutbound(&.{ "abc", "de" });
    defer outbound.deinit();
    try std.testing.expectEqual(@as(usize, 1), outbound.packets().len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 3, 'a', 'b', 'c', 0, 2, 'd', 'e' },
        outbound.packets()[0],
    );

    var partial = try processor.processInbound(&.{outbound.packets()[0][0..4]});
    defer partial.deinit();
    try std.testing.expectEqual(@as(usize, 0), partial.packets().len);

    var completed = try processor.processInbound(&.{outbound.packets()[0][4..]});
    defer completed.deinit();
    try std.testing.expectEqual(@as(usize, 2), completed.packets().len);
    try std.testing.expectEqualStrings("abc", completed.packets()[0]);
    try std.testing.expectEqualStrings("de", completed.packets()[1]);
}
