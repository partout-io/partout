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
        errdefer core_mod.util.deinitListOfStrings(allocator, &packets);
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
            try core_mod.util.appendOwned(
                allocator,
                &packets,
                zeroing.*.bytes[0..zeroing.*.length],
            );
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
        if (offset != capacity)
            @panic("OpenVPN stream serializer wrote a length different from its advertised capacity");
        return allocator.dupe(u8, zeroing.*.bytes[0..offset]);
    }
};

/// Applies OpenVPN XOR processing and TCP packet framing around LINK traffic.
///
/// Transport behavior is bound once at creation through `before_read` and
/// `before_write`. The read buffer only allocates storage when TCP input is
/// buffered.
///
/// Unlike the Swift closure pair, the Zig API returns explicit ownership so
/// callers can retain output through a synchronous `Looper.write()` call.
pub const LinkProcessor = struct {
    const Self = @This();
    const BeforeRead = *const fn (
        self: *Self,
        packets: []const []const u8,
    ) error{OutOfMemory}![][]u8;
    const BeforeWrite = *const fn (
        self: *const Self,
        packets: []const []const u8,
    ) error{ OutOfMemory, PacketTooLarge }![][]u8;

    allocator: std.mem.Allocator,
    processor: PacketProcessor,
    read_buffer: std.ArrayList(u8) = .empty,
    before_read: BeforeRead,
    before_write: BeforeWrite,

    pub const Output = struct {
        allocator: std.mem.Allocator,
        owned_packets: [][]u8,

        pub fn packets(self: Output) []const []const u8 {
            return @ptrCast(self.owned_packets);
        }

        pub fn deinit(self: *Output) void {
            core_mod.util.freeSliceOfStrings(self.allocator, self.owned_packets);
        }
    };

    pub fn create(
        allocator: std.mem.Allocator,
        method: ?api.OpenVPNObfuscationMethod,
        is_tcp: bool,
    ) !*LinkProcessor {
        const self = try allocator.create(LinkProcessor);
        errdefer allocator.destroy(self);
        var processor = try PacketProcessor.init(allocator, method);
        errdefer processor.deinit();
        self.* = .{
            .allocator = allocator,
            .processor = processor,
            .before_read = if (is_tcp) processTCPInbound else processUDPInbound,
            .before_write = if (is_tcp) processTCPOutbound else processUDPOutbound,
        };
        return self;
    }

    pub fn destroy(self: *LinkProcessor) void {
        self.read_buffer.deinit(self.allocator);
        self.processor.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn processInbound(
        self: *LinkProcessor,
        packets: []const []const u8,
    ) !Output {
        return .{
            .allocator = self.allocator,
            .owned_packets = try self.before_read(self, packets),
        };
    }

    pub fn processOutbound(
        self: *const LinkProcessor,
        packets: []const []const u8,
    ) !Output {
        return .{
            .allocator = self.allocator,
            .owned_packets = try self.before_write(self, packets),
        };
    }

    fn processUDPInbound(
        self: *LinkProcessor,
        packets: []const []const u8,
    ) error{OutOfMemory}![][]u8 {
        return self.processor.processPackets(
            self.allocator,
            packets,
            PacketDirection.inbound,
        );
    }

    fn processUDPOutbound(
        self: *const LinkProcessor,
        packets: []const []const u8,
    ) error{ OutOfMemory, PacketTooLarge }![][]u8 {
        return self.processor.processPackets(
            self.allocator,
            packets,
            PacketDirection.outbound,
        );
    }

    fn processTCPOutbound(
        self: *const LinkProcessor,
        packets: []const []const u8,
    ) error{ OutOfMemory, PacketTooLarge }![][]u8 {
        if (packets.len == 0) return self.allocator.alloc([]u8, 0);
        const stream = try self.processor.streamFromPackets(self.allocator, packets);
        errdefer self.allocator.free(stream);
        const result = try self.allocator.alloc([]u8, 1);
        result[0] = stream;
        return result;
    }

    fn processTCPInbound(
        self: *LinkProcessor,
        packets: []const []const u8,
    ) ![][]u8 {
        var additional: usize = 0;
        for (packets) |packet| additional = std.math.add(usize, additional, packet.len) catch return error.OutOfMemory;
        try self.read_buffer.ensureUnusedCapacity(self.allocator, additional);
        for (packets) |packet| self.read_buffer.appendSliceAssumeCapacity(packet);

        var consumed: usize = 0;
        const result = try self.processor.packetsFromStream(
            self.allocator,
            self.read_buffer.items,
            &consumed,
        );
        if (consumed > self.read_buffer.items.len)
            @panic("OpenVPN stream parser consumed beyond its input buffer");
        if (consumed > 0) {
            const remaining = self.read_buffer.items[consumed..];
            std.mem.copyForwards(u8, self.read_buffer.items[0..remaining.len], remaining);
            self.read_buffer.shrinkRetainingCapacity(remaining.len);
        }
        return result;
    }
};
