// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const DataChannel = @import("data_channel.zig").DataChannel;
const data_path = @import("data_path_protocol.zig");
const LinkProcessor = @import("link_processor.zig").LinkProcessor;

/// Encrypts/decrypts data-channel packets and moves them between LINK and TUN.
///
/// Every method is expected to execute on the owning session's looper thread.
/// In particular, timeout writes use the looper's out-of-band path, whose API
/// deliberately rejects calls from any other thread.
pub const DataLink = struct {
    allocator: std.mem.Allocator,
    looper: *net.Looper,
    link_processor: *LinkProcessor,
    context: ?*anyopaque,
    callbacks: Callbacks,

    pub const Callbacks = struct {
        data_channel: *const fn (?*anyopaque, u8) ?*DataChannel,
        report_inbound_data_count: *const fn (?*anyopaque, usize) void,
        report_outbound_data_count: *const fn (?*anyopaque, usize) void,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        looper: *net.Looper,
        link_processor: *LinkProcessor,
        context: ?*anyopaque,
        callbacks: Callbacks,
    ) DataLink {
        return .{
            .allocator = allocator,
            .looper = looper,
            .link_processor = link_processor,
            .context = context,
            .callbacks = callbacks,
        };
    }

    pub fn receive(
        self: *DataLink,
        packets: []const []const u8,
        key: u8,
    ) anyerror!void {
        self.receiveUnwrapped(packets, key) catch |err|
            return mapInboundError(err);
    }

    fn receiveUnwrapped(
        self: *DataLink,
        packets: []const []const u8,
        key: u8,
    ) anyerror!void {
        const channel = self.callbacks.data_channel(self.context, key) orelse return;
        const decrypted = try channel.decrypt(self.allocator, packets);
        defer data_path.freePackets(self.allocator, decrypted);
        if (decrypted.len == 0) return;

        self.callbacks.report_inbound_data_count(
            self.context,
            flatCount(decrypted),
        );
        try self.looper.writeQueued(asConstPackets(decrypted), .tun);
    }

    pub fn send(
        self: *DataLink,
        packets: []const []const u8,
        key: u8,
        timeout_ms: ?u64,
    ) anyerror!void {
        const channel = self.callbacks.data_channel(self.context, key) orelse return;
        const encrypted = try channel.encrypt(self.allocator, packets);
        defer data_path.freePackets(self.allocator, encrypted);
        if (encrypted.len == 0) return;

        self.callbacks.report_outbound_data_count(
            self.context,
            flatCount(encrypted),
        );

        var processed = try self.link_processor.processOutbound(asConstPackets(encrypted));
        defer processed.deinit();

        const timeout = timeout_ms orelse {
            try self.looper.writeQueued(processed.packets(), .link);
            return;
        };
        if (!self.looper.isOnQueue()) return error.ReentrantCall;

        const start = core.concurrency.monotonicNs();
        const deadline = start +| timeout *| @as(u64, std.time.ns_per_ms);
        var last_error: ?anyerror = null;
        while (true) {
            self.looper.write(processed.packets(), .link, true) catch |err| {
                last_error = err;
                if (core.concurrency.monotonicNs() < deadline) continue;
                return last_error orelse error.WriteTimeout;
            };
            return;
        }
    }

    fn flatCount(packets: []const []u8) usize {
        var result: usize = 0;
        for (packets) |packet| result +|= packet.len;
        return result;
    }

    fn asConstPackets(packets: []const []u8) []const []const u8 {
        // Slice mutability is not part of the packet identity. The returned
        // view borrows the exact same rows and is used only for synchronous
        // processing/copying by PacketProcessor and Looper.
        return @ptrCast(packets);
    }

    fn mapInboundError(err: anyerror) anyerror {
        // Swift deliberately preserves the two native wrapper families while
        // turning allocation, looper, and other inbound failures into a
        // recoverable session error.
        return switch (err) {
            error.CryptoHMAC,
            error.CryptoEncryption,
            error.CryptoFailure,
            error.DataPathPeerIdMismatch,
            error.DataPathCompression,
            error.DataPathFailure,
            => err,
            else => error.Recoverable,
        };
    }
};

test "DataLink declarations are semantically analyzed" {
    std.testing.refAllDecls(DataLink);
}

test "DataLink preserves only native inbound crypto/data-path failures" {
    try std.testing.expectEqual(error.CryptoHMAC, DataLink.mapInboundError(error.CryptoHMAC));
    try std.testing.expectEqual(error.DataPathCompression, DataLink.mapInboundError(error.DataPathCompression));
    try std.testing.expectEqual(error.Recoverable, DataLink.mapInboundError(error.DataPathOverflow));
    try std.testing.expectEqual(error.Recoverable, DataLink.mapInboundError(error.OutOfMemory));
}
