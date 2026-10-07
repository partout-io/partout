// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const net = @import("../../net/exports.zig");
const c = @import("wireguard_c");
const backend = @import("backend.zig");
const Endpoint = c.wg_endpoint;

/// Nonblocking native I/O called directly by Go workers. The bridge owns
/// descriptors and serializes each native call with replacement and cleanup.
/// Go handles retry waits; no native worker or looper retains borrowed buffers.
pub const PassiveIO = struct {
    lock: @import("../../core/exports.zig").Mutex = .{},
    complete: *const fn (usize, u32, i32) callconv(.c) void,
    link: ?net.LinkDescriptor = null,
    tun: ?net.TunDescriptor = null,
    closed: bool = true,

    pub fn replaceLink(self: *PassiveIO, descriptor: net.LinkDescriptor) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.link) |*link| link.cleanup();
        self.link = descriptor;
        self.closed = false;
    }

    pub fn replaceTun(self: *PassiveIO, descriptor: net.TunDescriptor) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.closed) {
            var rejected = descriptor;
            rejected.cleanup();
            return;
        }
        if (self.tun) |*tun| tun.cleanup();
        self.tun = descriptor;
    }

    pub fn hasIO(self: *PassiveIO) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.link != null or self.tun != null;
    }

    /// Excludes in-flight native calls and rejects subsequent Go requests.
    pub fn quiesce(self: *PassiveIO) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.closed = true;
    }

    pub fn release(self: *PassiveIO) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.closed = true;
        if (self.link) |*link| link.cleanup();
        self.link = null;
        if (self.tun) |*tun| tun.cleanup();
        self.tun = null;
    }

    pub fn transport(self: *PassiveIO, port: u16, mtu: u32) backend.StartTunnelPassive {
        return .{
            .link = .{ .local_port = port, .read = readLink, .write = writeLink },
            .tun = .{ .mtu = mtu, .read = readTun, .write = writeTun },
            .context = self,
        };
    }

    fn readLink(raw: ?*anyopaque, packets: [*c]c.wg_read_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.readBatch(.link, packets, count, request);
    }
    fn readTun(raw: ?*anyopaque, packets: [*c]c.wg_read_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.readBatch(.tun, packets, count, request);
    }

    fn readBatch(self: *PassiveIO, side: net.Side, packets: [*c]c.wg_read_packet, count: u32, request: usize) i32 {
        if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return c.WG_IO_INVALID;
        for (packets[0..count]) |packet| if (packet.data == null or packet.capacity == 0) {
            return c.WG_IO_INVALID;
        };
        self.lock.lock();
        if (self.closed) {
            self.lock.unlock();
            return c.WG_IO_CLOSED;
        }
        // Windows native descriptor I/O is not implemented yet.
        if (@import("builtin").os.tag == .windows) {
            self.lock.unlock();
            return c.WG_IO_INVALID;
        }
        const descriptor = if (side == .link) self.link else self.tun;
        var completed: u32 = 0;
        var status: i32 = c.WG_IO_AGAIN;
        if (descriptor) |value| {
            for (packets[0..count]) |*packet| {
                var address = std.mem.zeroes(net.SocketAddress);
                const size = value.io.readPacket(packet.data[0..packet.capacity], &address) catch |err| {
                    if (err != error.WouldBlock and err != error.DatagramDropped) status = c.WG_IO_INVALID;
                    break;
                } orelse break;
                packet.size = @intCast(size);
                if (side == .link) {
                    if (value.io == .socket and !value.io.isUnconnected()) {
                        address = value.io.socket.remoteAddress() orelse address;
                    }
                    packet.source = toEndpoint(address);
                }
                completed += 1;
            }
        }
        if (completed != 0) status = c.WG_IO_OK;
        self.lock.unlock();
        // Inline completion: all descriptor/payload access ends before this.
        self.complete(request, completed, status);
        return c.WG_IO_OK;
    }

    fn writeLink(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, destination: [*c]const Endpoint, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        if (destination == null) return c.WG_IO_INVALID;
        const address = fromEndpoint(destination.*) catch return c.WG_IO_INVALID;
        return self.writeBatch(.link, packets, count, address, request);
    }
    fn writeTun(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.writeBatch(.tun, packets, count, null, request);
    }
    fn writeBatch(self: *PassiveIO, side: net.Side, packets: [*c]const c.wg_packet, count: u32, destination: ?net.SocketAddress, request: usize) i32 {
        if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return c.WG_IO_INVALID;
        for (packets[0..count]) |packet| if (packet.size > 65535 or (packet.size != 0 and packet.data == null) or (side == .tun and packet.size == 0)) {
            return c.WG_IO_INVALID;
        };
        self.lock.lock();
        if (self.closed) {
            self.lock.unlock();
            return c.WG_IO_CLOSED;
        }
        if (@import("builtin").os.tag == .windows) {
            self.lock.unlock();
            return c.WG_IO_INVALID;
        }
        const descriptor = if (side == .link) self.link else self.tun;
        var completed: u32 = 0;
        var status: i32 = c.WG_IO_AGAIN;
        if (descriptor) |value| {
            for (packets[0..count]) |packet| {
                const data: []const u8 = if (packet.size == 0) &.{} else packet.data[0..packet.size];
                const size = value.io.writePacket(data, 0, destination) catch |err| {
                    if (err != error.WouldBlock and err != error.Backpressure) status = c.WG_IO_INVALID;
                    break;
                };
                if (size != data.len) {
                    status = c.WG_IO_INVALID;
                    break;
                }
                completed += 1;
            }
        }
        if (completed == count) status = c.WG_IO_OK;
        self.lock.unlock();
        self.complete(request, completed, status);
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

pub const testing = struct {
    pub const abi = c;
};
