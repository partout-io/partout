// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const helpers_mod = @import("helpers.zig");

const api = core_mod.api;
const c = helpers_mod.c;
const c_common = c_exports_mod.common;

pub const PacketDirection = enum {
    outbound,
    inbound,
};

pub const PacketProcessor = struct {
    ptr: *c.openvpn_pkt_proc,

    pub fn init(
        allocator: std.mem.Allocator,
        method: ?api.OpenVPNObfuscationMethod,
    ) !PacketProcessor {
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
        direction: PacketDirection,
    ) ![]u8 {
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
        direction: PacketDirection,
    ) ![][]u8 {
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
    ) ![][]u8 {
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

    pub fn streamFromPackets(
        self: *const PacketProcessor,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) ![]u8 {
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

    fn freePacketList(allocator: std.mem.Allocator, packets: *std.ArrayList([]u8)) void {
        for (packets.items) |packet| allocator.free(packet);
        packets.deinit(allocator);
    }
};

/// Applies OpenVPN XOR processing and TCP packet framing around LINK traffic.
///
/// Unlike the Swift closure pair, the Zig API returns explicit ownership so
/// callers can retain output through a synchronous `Looper.write()` call.
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
            core_mod.util.freeSliceOfStrings(self.allocator, self.owned_packets);
            self.* = undefined;
        }
    };

    pub fn create(
        allocator: std.mem.Allocator,
        method: ?api.OpenVPNObfuscationMethod,
        is_tcp: bool,
    ) !*LinkProcessor {
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
    ) !Output {
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
        self: *const LinkProcessor,
        packets: []const []const u8,
    ) !Output {
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
    ) ![][]u8 {
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
