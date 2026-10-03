// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const net = @import("../../net/exports.zig");
const c = @import("wireguard_c");
const backend = @import("backend.zig");
const Endpoint = c.wg_endpoint;

/// Go packet bridge only. The daemon owns every descriptor and attachment.
/// Lifecycle and receive calls run on its looper; Go writes enqueue copies.
pub const PassiveIO = struct {
    allocator: std.mem.Allocator,
    backend: backend.Backend,
    looper: ?*net.Looper = null,
    handle: i32 = -1,
    active: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *PassiveIO, remote: net.RemoteDescriptor, mtu: u32, settings: [:0]const u8) !void {
        if (self.handle >= 0 or remote.local_port == 0 or remote.looper.implementation != .experimental) return error.TransportFailure;
        if (self.backend.vtable.receive_datagrams == null or self.backend.vtable.receive_tun_packets == null) return error.TransportFailure;
        self.looper = remote.looper;
        self.active.store(true, .release);
        errdefer self.active.store(false, .release);
        const handle = try self.backend.turnOn(self.allocator, settings, .{
            .passive = .{
                .link = .{ .local_port = remote.local_port, .write = writeLink },
                .tun = .{ .mtu = mtu, .write = writeTun },
                .context = self,
            },
        });
        if (handle < 0) return error.TransportFailure;
        self.handle = handle;
    }

    /// Joins Go callbacks before the owner detaches its I/O or frees this bridge.
    pub fn stop(self: *PassiveIO) void {
        self.active.store(false, .release);
        if (self.handle >= 0) self.backend.turnOff(self.handle);
        self.handle = -1;
    }

    pub fn receiveTun(self: *PassiveIO, packets: net.Looper.Packets) !void {
        if (!self.active.load(.acquire)) return;
        var batch: [c.WG_IO_MAX_BATCH]c.wg_packet = undefined;
        var offset: usize = 0;
        while (offset < packets.len) {
            const count = @min(batch.len, packets.len - offset);
            for (packets[offset..][0..count], batch[0..count]) |packet, *entry| {
                entry.* = .{ .data = packet.ptr, .size = @intCast(packet.len) };
            }
            try checkStatus(self.backend.vtable.receive_tun_packets.?(self.handle, &batch, @intCast(count)));
            offset += count;
        }
    }

    pub fn receiveLink(self: *PassiveIO, packets: net.Looper.Packets, sources: []const net.SocketAddress) !void {
        if (!self.active.load(.acquire)) return;
        if (packets.len != sources.len) return error.TransportFailure;
        var batch: [c.WG_IO_MAX_BATCH]c.wg_packet = undefined;
        var endpoints: [c.WG_IO_MAX_BATCH]Endpoint = undefined;
        var offset: usize = 0;
        while (offset < packets.len) {
            const count = @min(batch.len, packets.len - offset);
            for (packets[offset..][0..count], sources[offset..][0..count], batch[0..count], endpoints[0..count]) |packet, source, *entry, *endpoint| {
                entry.* = .{ .data = packet.ptr, .size = @intCast(packet.len) };
                endpoint.* = toEndpoint(source);
            }
            try checkStatus(self.backend.vtable.receive_datagrams.?(self.handle, &batch, &endpoints, @intCast(count)));
            offset += count;
        }
    }

    fn checkStatus(status: i32) !void {
        switch (status) {
            c.WG_IO_OK, c.WG_IO_QUEUE_FULL => {},
            else => return error.TransportFailure,
        }
    }

    fn writeLink(raw: ?*anyopaque, packet: [*c]const u8, size: u32, destination: [*c]const Endpoint) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        if (destination == null or (size != 0 and packet == null) or size > 65535) return c.WG_IO_INVALID;
        if (!self.active.load(.acquire)) return c.WG_IO_CLOSED;
        const address = fromEndpoint(destination.*) catch return c.WG_IO_INVALID;
        const data: []const u8 = if (size == 0) &.{} else packet[0..size];
        self.looper.?.writeQueued(&.{data}, .link, address) catch return c.WG_IO_CLOSED;
        return c.WG_IO_OK;
    }

    fn writeTun(raw: ?*anyopaque, packet: [*c]const u8, size: u32) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        if (size == 0 or size > 65535 or packet == null) return c.WG_IO_INVALID;
        if (!self.active.load(.acquire)) return c.WG_IO_CLOSED;
        self.looper.?.writeQueued(&.{packet[0..size]}, .tun, null) catch return c.WG_IO_CLOSED;
        return c.WG_IO_OK;
    }
};

fn toEndpoint(address: net.SocketAddress) Endpoint {
    return .{
        .address = address.address,
        .scope_id = address.scope_id,
        .port = address.port,
        .family = address.family,
    };
}

fn fromEndpoint(endpoint: Endpoint) !net.SocketAddress {
    if (endpoint.family != 4 and endpoint.family != 6) return error.InvalidAddressFamily;
    if (endpoint.family == 4 and endpoint.scope_id != 0) return error.InvalidScope;
    var address = std.mem.zeroes(net.SocketAddress);
    address.address = endpoint.address;
    address.scope_id = endpoint.scope_id;
    address.port = endpoint.port;
    address.family = endpoint.family;
    return address;
}
