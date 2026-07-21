// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const PacketDirection = @import("packet_direction.zig").PacketDirection;
const PacketProcessor = @import("packet_processor.zig").PacketProcessor;

const api = core.api;

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
