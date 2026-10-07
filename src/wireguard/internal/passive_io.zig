// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const net = @import("../../net/exports.zig");
const c = @import("wireguard_c");
const backend = @import("backend.zig");
const Endpoint = c.wg_endpoint;

/// Go packet bridge only. The daemon owns every descriptor and attachment.
/// The daemon lends Go buffers to native I/O and cancels writes on detach.
pub const PassiveIO = struct {
    lock: @import("../../core/exports.zig").Mutex = .{},
    reads: [2]ReadSlot = .{ .{}, .{} },
    allocator: std.mem.Allocator,
    complete: *const fn (usize, u32, i32) callconv(.c) void,
    looper: ?*net.Looper = null,
    state: State = .closed, // Protected by lock, including Go callback threads.

    const State = enum(u8) { closed, link_paused, active };

    pub fn activate(self: *PassiveIO, looper: *net.Looper) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.looper = looper;
        self.state = .active;
    }

    /// Retain pending link reads during socket replacement; TUN stays live.
    pub fn pauseLink(self: *PassiveIO) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.state = .link_paused;
    }

    pub fn transport(self: *PassiveIO, port: u16, mtu: u32) backend.StartTunnel {
        return .{ .passive = .{
            .link = .{ .local_port = port, .read = readLink, .write = writeLink },
            .tun = .{ .mtu = mtu, .read = readTun, .write = writeTun },
            .context = self,
        } };
    }

    /// Runs on the looper. Stop admission before the daemon detaches native I/O.
    /// Read loans cannot be active here: acquire/release also run on this queue.
    pub fn quiesce(self: *PassiveIO) void {
        self.lock.lock();
        self.state = .closed;
        var requests: [2]usize = .{ 0, 0 };
        for (&self.reads, &requests) |*slot, *request| {
            request.* = slot.takeRequest();
        }
        self.lock.unlock();
        for (requests) |request| if (request != 0) {
            self.complete(request, 0, c.WG_IO_CLOSED);
        };
    }

    pub fn readBuffers(self: *PassiveIO, side: net.Side) net.Looper.ReadBuffers {
        const slot = &self.reads[if (side == .link) @as(usize, 0) else 1];
        slot.owner = self;
        return .{ .context = slot, .acquire = ReadSlot.acquire, .release = ReadSlot.release };
    }

    const ReadSlot = struct {
        owner: *PassiveIO = undefined,
        request: usize = 0,
        packets: [*c]c.wg_read_packet = null,
        count: usize = 0,
        needs_resume: bool = true,
        buffers: [c.WG_IO_MAX_BATCH]net.Looper.ReadBuffer = undefined,

        // Caller holds the bridge lock and completes the returned request
        // after unlocking. No buffers may be accessed after completion.
        fn takeRequest(self: *ReadSlot) usize {
            const request = self.request;
            self.request = 0;
            self.packets = null;
            self.count = 0;
            return request;
        }

        fn acquire(raw: ?*anyopaque) []net.Looper.ReadBuffer {
            const slot: *ReadSlot = @ptrCast(@alignCast(raw.?));
            slot.owner.lock.lock();
            defer slot.owner.lock.unlock();
            // An empty acquisition makes the looper pause. Publishing buffers
            // only needs a wake in that case, not after every completed read.
            if (slot.count == 0) slot.needs_resume = true;
            return slot.buffers[0..slot.count];
        }
        fn release(raw: ?*anyopaque, _: []net.Looper.ReadBuffer, result: net.Looper.IOResult) void {
            const slot: *ReadSlot = @ptrCast(@alignCast(raw.?));
            const owner = slot.owner;
            owner.lock.lock();
            if (slot.request == 0 or (result.count == 0 and result.failure == null)) {
                owner.lock.unlock();
                return;
            }
            for (slot.buffers[0..result.count], slot.packets[0..result.count]) |buffer, *packet| {
                packet.size = @intCast(buffer.size);
                if (buffer.source) |source| packet.source = toEndpoint(source);
            }
            const request = slot.takeRequest();
            owner.lock.unlock();
            owner.complete(request, @intCast(result.count), ioStatus(result));
        }
    };

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
        defer self.lock.unlock();
        if (self.state == .closed) return c.WG_IO_CLOSED;
        const slot = &self.reads[if (side == .link) @as(usize, 0) else 1];
        if (slot.request != 0) return c.WG_IO_INVALID;
        for (packets[0..count], slot.buffers[0..count]) |packet, *buffer| {
            buffer.* = .{ .data = packet.data[0..packet.capacity] };
        }
        slot.request = request;
        slot.packets = packets;
        slot.count = count;
        const looper = self.looper.?;
        const attached = if (side == .link) looper.isLinkAttached() else looper.isTunAttached();
        if (slot.needs_resume and attached and (self.state == .active or side == .tun)) {
            looper.resumeReading(side) catch {
                _ = slot.takeRequest();
                return c.WG_IO_CLOSED;
            };
            slot.needs_resume = false;
        }
        return c.WG_IO_OK;
    }

    const WriteLoan = struct {
        allocator: std.mem.Allocator,
        complete: *const fn (usize, u32, i32) callconv(.c) void,
        request: usize,
        packets: [c.WG_IO_MAX_BATCH][]const u8 = undefined,
        fn finish(raw: ?*anyopaque, result: net.Looper.IOResult) void {
            const self: *WriteLoan = @ptrCast(@alignCast(raw.?));
            const complete = self.complete;
            const request = self.request;
            self.allocator.destroy(self);
            complete(request, @intCast(result.count), ioStatus(result));
        }
    };
    fn ioStatus(result: net.Looper.IOResult) i32 {
        if (result.failure) |err| return if (err == error.Cancelled) c.WG_IO_CLOSED else c.WG_IO_INVALID;
        return c.WG_IO_OK;
    }
    fn writeLink(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, destination: [*c]const Endpoint, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        if (destination == null) return c.WG_IO_INVALID;
        const address = fromEndpoint(destination.*) catch return c.WG_IO_INVALID;
        return self.writeBorrowed(packets, count, .link, address, request);
    }
    fn writeTun(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.writeBorrowed(packets, count, .tun, null, request);
    }
    fn writeBorrowed(self: *PassiveIO, packets: [*c]const c.wg_packet, count: u32, side: net.Side, destination: ?net.SocketAddress, request: usize) i32 {
        if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return c.WG_IO_INVALID;
        self.lock.lock();
        defer self.lock.unlock();
        switch (self.state) {
            .closed => return c.WG_IO_CLOSED,
            .link_paused => if (side == .link) return c.WG_IO_INVALID,
            .active => {},
        }
        const loan = self.allocator.create(WriteLoan) catch return c.WG_IO_INVALID;
        loan.* = .{ .allocator = self.allocator, .complete = self.complete, .request = request };
        for (packets[0..count], loan.packets[0..count]) |packet, *entry| {
            if (packet.size > 65535 or (packet.size != 0 and packet.data == null) or (side == .tun and packet.size == 0)) {
                self.allocator.destroy(loan);
                return c.WG_IO_INVALID;
            }
            entry.* = if (packet.size == 0) &.{} else packet.data[0..packet.size];
        }
        self.looper.?.writeBorrowed(loan.packets[0..count], side, destination, .{ .context = loan, .callback = WriteLoan.finish }) catch {
            self.allocator.destroy(loan);
            return c.WG_IO_CLOSED;
        };
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
